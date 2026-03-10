# Vultr Benchmark Orchestration

> ⚠️ **Fair warning:** This was vibe-coded from a plane using [OpenClaw](https://github.com/openclaw/openclaw). It works, but don't expect enterprise-grade polish. PRs welcome, flames not so much. 🦀✈️

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
uv run orchestrate_vultr.py --count 10

# Or override with an explicit list
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
| `--models`   | _(optional)_                                | Model IDs to benchmark (space-separated)            |
| `--models-file` | `default-models.yml`                     | YAML file used when `--models` is not provided      |
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

See [docs/bootstrapping-snapshot.md](docs/bootstrapping-snapshot.md)

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
