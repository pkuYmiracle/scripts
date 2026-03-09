# Vultr Benchmark Orchestration

Instances are created with a model list baked into their userdata, run benchmarks
autonomously, and self-destruct when done. Your laptop only needs to be running
long enough to fire the `vultr instance create` calls (~10 seconds).

## How It Works

```
Your laptop                    Vultr API              Vultr Instance
    |                              |                        |
    |-- instance create x N ------>|                        |
    |   (userdata = model list)    |                        |
    |<-- instance IDs -------------|                        |
    |  [laptop can close now]      |                        |
                                   |-- boots from snapshot ->|
                                                            |-- reads models from
                                                            |   metadata API
                                                            |-- uv run benchmark.py --register
                                                            |-- [Slack: started + claim URL]
                                                            |-- uv run benchmark.py --model ...
                                                            |-- uv run benchmark.py --model ...
                                                            |-- [Slack: done + result URLs]
                                                            |-- vultr instance delete $SELF
```

Each instance also schedules a safety-net self-destruct via `at now + 5 hours` at
startup, so orphaned instances are cleaned up even if the runner crashes.

## Running Benchmarks

```bash
uv run orchestrate_vultr.py --count 10 \
  --models \
  anthropic/claude-opus-4.5 \
  openai/gpt-4o \
  google/gemini-2.5-flash \
  ...
```

Models are distributed round-robin across instances (e.g. 30 models across 10
instances = 3 models per instance). The script exits as soon as all instances are
created.

**Options:**

| Option       | Default                                     | Description                                         |
| ------------ | ------------------------------------------- | --------------------------------------------------- |
| `--models`   | _required_                                  | Model IDs to benchmark (space-separated)            |
| `--count`    | `1`                                         | Number of instances; models distributed across them |
| `--region`   | `atl`                                       | Vultr region                                        |
| `--plan`     | `vc2-1c-2gb`                                | Vultr instance plan                                 |
| `--snapshot` | _(see VultrConfig in orchestrate_vultr.py)_ | Vultr snapshot ID — update after re-bootstrapping   |
| `--ssh-keys` | `a4b8f6d9-...`                              | Vultr SSH key ID                                    |

**Monitoring:**

```bash
# Watch instances disappear as they finish
watch vultr instance list

# Tail logs on a running instance
ssh root@<ip> tail -f /var/log/bench-runner.log

# View systemd service output
ssh root@<ip> journalctl -u bench-runner -f
```

---

## Bootstrapping a New Vultr Snapshot

Do this whenever the snapshot is lost or needs to be rebuilt from scratch.
The snapshot is what all benchmark instances boot from — it contains the repo,
all dependencies, API keys, and the runner service.

### 1. Create a fresh base instance

Use a plain Ubuntu 22.04 image (not the old snapshot):

```bash
vultr instance create \
  --region atl \
  --plan vc2-1c-2gb \
  --os 1743 \
  --label bench-bootstrap \
  --ssh-keys a4b8f6d9-fa2e-48a4-b12d-b6162d065e52 \
  --output json
```

Wait for it to become active and get its IP:

```bash
vultr instance list
```

### 2. Copy the setup files to the instance

```bash
scp scripts/bootstrap_instance.sh \
    scripts/bench_runner.sh \
    scripts/bench-runner.service \
    root@<ip>:/tmp/
```

### 3. Run the bootstrap script

```bash
ssh root@<ip> 'bash /tmp/bootstrap_instance.sh'
```

The script will prompt for:

| Credential               | Where to find it                                             |
| ------------------------ | ------------------------------------------------------------ |
| `OPENROUTER_API_KEY`     | `skill/.env`                                                 |
| `PINCHBENCH_TOKEN`       | `skill/.env`                                                 |
| `VULTR_API_KEY`          | Vultr portal → Account → API                                 |
| `PINCHBENCH_OFFICIAL_KEY`| `skill/.env` (optional — skip for unofficial submissions)    |
| `SLACK_WEBHOOK_URL`      | Slack app webhook (optional — skip to disable notifications) |

It installs Node 22, uv, vultr-cli, OpenClaw, clones the skill repo, pre-installs
Python deps, writes credentials to `/etc/environment`, installs and enables
`bench-runner.service`, and resets cloud-init.

The bootstrap script is idempotent — if it fails partway through, fix the issue
and re-run it. Already-installed tools will be skipped.

### 4. Take the snapshot

Take the snapshot while the instance is **still running**. Snapshots taken from
stopped instances boot into a stopped state, which breaks the orchestrator.

```bash
vultr snapshot create \
  -i <id> \
  -d "bench-runner $(date +%Y-%m-%d)"
```

Wait for the snapshot status to become `complete`:

```bash
watch vultr snapshot list
```

### 5. Update the snapshot ID

Update the snapshot ID in two places:

**`scripts/orchestrate_vultr.py`** — `VultrConfig.snapshot` default:

```python
snapshot: str = "<new-snapshot-id>"
```

**`scripts/create_instance.sh`** — the `--snapshot` comment at the top.

### 6. Delete the bootstrap instance

It's stopped but still billing:

```bash
vultr instance delete <id>
```

---

## Files

| File                    | Purpose                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------- |
| `orchestrate_vultr.py`  | Fire-and-forget launcher — creates instances and exits                                      |
| `bench_runner.sh`       | Runs on each instance; reads models from metadata, benchmarks, self-destructs               |
| `bench-runner.service`  | systemd unit that starts `bench_runner.sh` on first boot                                    |
| `bootstrap_instance.sh` | One-shot setup script for building a new snapshot image                                     |
| `setup_snapshot.sh`     | Lighter alternative to bootstrap — installs just the runner files onto an existing instance |
| `create_instance.sh`    | Convenience shell script with the full model list pre-filled                                |
| `delete_instances.sh`   | Emergency cleanup: delete instances by ID                                                   |
