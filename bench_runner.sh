#!/bin/bash
# Autonomous benchmark runner — runs on each Vultr instance at boot.
#
# Reads the model list from the Vultr instance metadata API (set as userdata
# by the orchestrator), runs registration and benchmarks for each model,
# then self-destructs the instance.
#
# This script is invoked by bench-runner.service (systemd) on first boot.
# It should be placed at /root/run_benchmarks.sh on the snapshot image.
# Use setup_snapshot.sh to install it.

set -o pipefail

LOG="/var/log/bench-runner.log"
REMOTE_DIR="/root/skill/scripts"
METADATA="http://169.254.169.254"

# Tee all output to log file
exec > >(tee -a "$LOG") 2>&1

# ── Load environment first, before strict mode ──
# .bashrc references $PS1 which is unbound in non-interactive shells.
# Source with -u disabled to avoid a fatal error, then enable strict mode.
source /root/.profile 2>/dev/null || true
source /root/.bashrc 2>/dev/null || true
set -o allexport
source /etc/environment 2>/dev/null || true
set +o allexport

# Ensure tool paths are present regardless of how systemd invoked this script
export PATH="/root/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:$PATH"

# Now enable strict mode (unbound variables are safe after sourcing profiles)
set -uo pipefail

# ── Slack notification helper ──
# Reads SLACK_WEBHOOK_URL from /etc/environment (set during snapshot setup).
# Silently no-ops if the variable is unset so the script still works without Slack.
slack_notify() {
    local text="$1"
    if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
        return 0
    fi
    curl -sf -X POST "$SLACK_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"text\": $(echo "$text" | jq -Rs .)}" \
        >/dev/null 2>&1 || echo "WARNING: Slack notification failed"
}

echo "=== Benchmark runner started at $(date -u) ==="
echo "Hostname: $(hostname)"

# ── Verify required tools ──
for tool in curl jq uv vultr; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: '$tool' not found in PATH (PATH=$PATH)"
        exit 1
    fi
done

# ── Get instance ID from Vultr metadata ──
echo "Fetching instance metadata..."
INSTANCE_ID=""
for attempt in $(seq 1 12); do
    INSTANCE_ID=$(curl -sf --retry 3 --retry-delay 5 "$METADATA/v1/instance-v2-id" 2>/dev/null || true)
    if [ -n "$INSTANCE_ID" ]; then
        break
    fi
    echo "  Metadata not ready (attempt $attempt/12), retrying in 10s..."
    sleep 10
done

if [ -z "$INSTANCE_ID" ]; then
    echo "ERROR: Could not retrieve instance ID from metadata API after 2 minutes"
    exit 1
fi

echo "Instance ID: $INSTANCE_ID"

# ── Register a safety-net self-destruct in 5 hours ──
# This fires even if the benchmarks hang or the runner crashes after registration.
# Requires 'at' to be available (installed by setup_snapshot.sh).
if command -v at &>/dev/null && [ -n "$INSTANCE_ID" ]; then
    echo "vultr instance delete $INSTANCE_ID --force" | at now + 5 hours 2>/dev/null && \
        echo "Safety-net self-destruct scheduled in 5 hours" || \
        echo "WARNING: Could not schedule safety-net self-destruct (at daemon not running?)"
fi

# ── Read model list from file ──
# The orchestrator creates a Vultr startup script per instance that writes
# /root/benchmark_models.txt (one model per line) at first boot.
# Startup scripts run regardless of snapshot vs OS image, unlike --userdata
# which is silently ignored on snapshot-based instances.
MODEL_FILE="/root/benchmark_models.txt"

# Wait for the startup script to run and write the file (it runs early in boot
# but may not be done by the time this service starts)
echo "Waiting for model assignment file..."
for attempt in $(seq 1 12); do
    if [ -s "$MODEL_FILE" ]; then
        break
    fi
    echo "  $MODEL_FILE not ready yet (attempt $attempt/12), waiting 10s..."
    sleep 10
done

if [ ! -s "$MODEL_FILE" ]; then
    echo "ERROR: $MODEL_FILE not found or empty after 2 minutes"
    echo "Was this instance launched by the orchestrator?"
    exit 1
fi

echo "Model assignment file:"
cat "$MODEL_FILE"

mapfile -t MODELS < "$MODEL_FILE"

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "ERROR: No models found in $MODEL_FILE"
    exit 1
fi

echo "Models assigned to this instance:"
for m in "${MODELS[@]}"; do
    echo "  - $m"
done

# ── Pull latest benchmark code ──
echo ""
echo "=== Updating benchmark code ==="
cd "$REMOTE_DIR"
git pull || echo "WARNING: git pull failed, continuing with existing code"

# ── Registration ──
echo ""
echo "=== Running registration ==="
# Use a temp file so output is both written to the log (via the exec redirect)
# and available for URL extraction. Command substitution $(...) runs in a subshell
# that doesn't inherit the exec redirect, so tee /dev/stderr wouldn't reach the log.
REG_TMPFILE=$(mktemp)
uv run benchmark.py --register 2>&1 | tee "$REG_TMPFILE"
REGISTER_EXIT=${PIPESTATUS[0]}
REGISTRATION_OUTPUT=$(cat "$REG_TMPFILE")
rm -f "$REG_TMPFILE"

if [ "$REGISTER_EXIT" -ne 0 ]; then
    echo "ERROR: Registration failed"
    slack_notify "❌ *bench-runner failed* on \`$(hostname)\` ($INSTANCE_ID)
Registration failed after assigning models: ${MODELS[*]}
Check: \`ssh root@$(curl -sf $METADATA/v1/interfaces/0/ipv4/address || echo unknown) tail -f $LOG\`"
    vultr instance delete "$INSTANCE_ID" --force || true
    exit 1
fi
echo "✓ Registration complete"

# Extract claim URL ("Claim URL: https://...") from registration output
CLAIM_URL=$(echo "$REGISTRATION_OUTPUT" | grep -i "Claim URL" | grep -oE 'https?://[^ ]+' | head -1 || true)

MODEL_LIST=$(printf ' • %s\n' "${MODELS[@]}")
slack_notify "🚀 *bench-runner started* on \`$(hostname)\` ($INSTANCE_ID)
Models (${#MODELS[@]}):
$MODEL_LIST
${CLAIM_URL:+Claim URL: $CLAIM_URL}"

# ── Run benchmarks ──
FAILED_MODELS=()
RESULT_URLS=()

for model in "${MODELS[@]}"; do
    echo ""
    echo "=== Benchmarking: $model ==="
    echo "Started at: $(date -u)"

    MODEL_TMPFILE=$(mktemp)
    uv run benchmark.py --model "$model" 2>&1 | tee "$MODEL_TMPFILE"
    MODEL_EXIT=${PIPESTATUS[0]}
    MODEL_OUTPUT=$(cat "$MODEL_TMPFILE")
    rm -f "$MODEL_TMPFILE"

    # Extract "View at: https://..." leaderboard URL from model run output
    MODEL_URL=$(echo "$MODEL_OUTPUT" | grep -i "View at" | grep -oE 'https?://[^ ]+' | head -1 || true)
    if [ -n "$MODEL_URL" ]; then
        RESULT_URLS+=("$model: $MODEL_URL")
    fi

    if [ "$MODEL_EXIT" -eq 0 ]; then
        echo "✓ $model complete at $(date -u)"
    else
        echo "✗ $model failed at $(date -u)"
        FAILED_MODELS+=("$model")
    fi
done

# ── Summary ──
echo ""
echo "=== Run complete at $(date -u) ==="
echo "Total models: ${#MODELS[@]}"
echo "Failed:       ${#FAILED_MODELS[@]}"
if [ ${#FAILED_MODELS[@]} -gt 0 ]; then
    echo "Failed models:"
    for m in "${FAILED_MODELS[@]}"; do
        echo "  - $m"
    done
fi

SUCCEEDED=$(( ${#MODELS[@]} - ${#FAILED_MODELS[@]} ))
if [ ${#FAILED_MODELS[@]} -eq 0 ]; then
    SUMMARY_EMOJI="✅"
    SUMMARY_STATUS="all ${#MODELS[@]} models completed"
else
    SUMMARY_EMOJI="⚠️"
    FAILED_LIST=$(printf ' • %s\n' "${FAILED_MODELS[@]}")
    SUMMARY_STATUS="$SUCCEEDED/${#MODELS[@]} succeeded. Failed:
$FAILED_LIST"
fi

RESULTS_SECTION=""
if [ ${#RESULT_URLS[@]} -gt 0 ]; then
    RESULTS_SECTION="
Results:
$(printf ' • %s\n' "${RESULT_URLS[@]}")"
fi

slack_notify "$SUMMARY_EMOJI *bench-runner done* on \`$(hostname)\` ($INSTANCE_ID)
$SUMMARY_STATUS
${CLAIM_URL:+Claim URL: $CLAIM_URL}$RESULTS_SECTION
Destroying instance now."

# ── Self-destruct ──
echo ""
echo "=== Deleting instance $INSTANCE_ID ==="
if vultr instance delete "$INSTANCE_ID" --force; then
    echo "✓ Instance deletion requested"
else
    echo "WARNING: Self-destruct failed — instance $INSTANCE_ID may need manual cleanup"
    echo "Run: vultr instance delete $INSTANCE_ID --force"
fi
