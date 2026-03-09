#!/usr/bin/env python3
"""
Fire-and-forget Vultr benchmark launcher.

Creates instances from a snapshot, waits for SSH, writes the model assignment
to /root/benchmark_models.txt, then disconnects. The bench-runner.service picks
up the file and runs benchmarks autonomously until done, then self-destructs.

Your laptop needs to stay online for ~60-90s per batch while instances boot and
SSH becomes available. After the model file is written you can close your laptop.

Vultr blocks both --userdata and --script-id for custom snapshot instances, so
SSH is the only reliable way to pass per-instance configuration.

Usage:
  uv run scripts/orchestrate_vultr.py --models anthropic/claude-opus-4.5 --count 1
  uv run scripts/orchestrate_vultr.py --models model1 model2 model3 --count 3

Options:
  --models:  Space-separated list of models to benchmark
  --count:   Number of instances to create (default: 1)
             Models are distributed round-robin across instances.
             e.g. 9 models across 3 instances = 3 models per instance.
  --workers: Parallel SSH workers for writing model files (default: 10)
  --key:     Path to SSH private key (default: ~/.ssh/id_ed25519)
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

try:
    import paramiko
except ImportError:
    print("ERROR: paramiko is required. Install with: uv pip install paramiko", file=sys.stderr)
    sys.exit(1)

# Pre-2026-03-08 snapshots
# benchrunner 2026-03-08 v0
# c59496ef-734f-48b6-9701-ed80729ddd35
#
# From previous snapshots
# bench-runner 2026-03-08 v1
# 38bffed6-4d09-4cf4-840d-0e0180eb0d89
#
# Full bootstrap
# bench-runner 2026-03-08 v2
# 3924b3f6-d99d-4c6f-8883-43d6d847ff6b
#
# Full bootstrap with fixes
# bench-runner 2026-03-08 v3
# 2fce88d3-b2e5-4605-8ed7-1f3865f07773
#
# Even more fixes
# bench-runner 2026-03-09 v4
# 1a13a7ee-6d61-4677-9ad4-4494368323a0
#
# Still running instance
# bench-runner 2026-03-09 v5
# a0af88a0-ec03-46bf-a288-e0f0ad859550
#
# Taken from running instance (bc8b003a @ 96.30.204.111) — boots correctly
# bench-runner 2026-03-09 v6
# 3528464a-4710-4e43-b2ff-47643fcabea4

DEFAULT_SNAPSHOT = "3528464a-4710-4e43-b2ff-47643fcabea4"


@dataclass(frozen=True)
class VultrConfig:
    """Configuration for Vultr instance creation."""

    region: str = "atl"
    plan: str = "vc2-1c-2gb"
    snapshot: str = DEFAULT_SNAPSHOT
    ssh_keys: str = "a4b8f6d9-fa2e-48a4-b12d-b6162d065e52"


def create_instance(label: str, config: VultrConfig) -> str:
    """Create a Vultr instance and return its ID."""
    result = subprocess.run(
        [
            "vultr",
            "instance",
            "create",
            "--region",
            config.region,
            "--plan",
            config.plan,
            "--snapshot",
            config.snapshot,
            "--ssh-keys",
            config.ssh_keys,
            "--label",
            label,
            "--output",
            "json",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    data = json.loads(result.stdout)
    instance_data = data.get("instance", data)
    return instance_data["id"]


def wait_for_ip(instance_id: str, timeout: int = 300, poll: int = 10) -> str:
    """
    Poll until the instance has an IP address and is running.

    If the instance boots into a stopped state (which happens when the snapshot
    was taken from a stopped instance), issue a start command automatically.
    """
    start = time.time()
    started = False
    while time.time() - start < timeout:
        result = subprocess.run(
            ["vultr", "instance", "get", instance_id, "--output", "json"],
            capture_output=True,
            text=True,
            check=True,
        )
        data = json.loads(result.stdout)
        instance_data = data.get("instance", data)
        status = instance_data.get("status")
        power = instance_data.get("power_status", "running")
        server = instance_data.get("server_status", "")
        ip = instance_data.get("main_ip", "0.0.0.0")

        if status == "active" and ip != "0.0.0.0":
            # If the instance is stopped (snapshot taken while shut down), start it
            if power == "stopped" and server != "locked" and not started:
                print(f"    Instance {instance_id} is stopped — starting it...")
                subprocess.run(
                    ["vultr", "instance", "start", instance_id],
                    capture_output=True,
                    check=False,
                )
                started = True
            elif power == "running":
                return ip

        time.sleep(poll)
    raise TimeoutError(f"Instance {instance_id} did not become active within {timeout}s")


def wait_for_ssh(ip: str, timeout: int = 600) -> None:
    """Wait until port 22 accepts connections."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection((ip, 22), timeout=5):
                return
        except (socket.timeout, ConnectionRefusedError, OSError):
            time.sleep(5)
    raise TimeoutError(f"SSH not available on {ip} after {timeout}s")


def write_model_file(ip: str, models: list[str], key_path: str) -> None:
    """
    SSH into the instance and write /root/benchmark_models.txt.

    This is a brief connection — we write one file and disconnect.
    The bench-runner.service is already running and waiting for this file.
    """
    key_path = os.path.expanduser(key_path)
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(ip, username="root", key_filename=key_path, timeout=30)
        model_content = "\n".join(models) + "\n"
        # Write atomically via temp file to avoid a race with the runner's polling
        escaped = model_content.replace("'", "'\\''")
        cmd = (
            f"printf '%s' '{escaped}' > /root/benchmark_models.txt.tmp && "
            f"mv /root/benchmark_models.txt.tmp /root/benchmark_models.txt"
        )
        _, stdout, stderr = client.exec_command(cmd)
        exit_status = stdout.channel.recv_exit_status()
        if exit_status != 0:
            err = stderr.read().decode().strip()
            raise RuntimeError(f"Failed to write model file on {ip}: {err}")
    finally:
        client.close()


def launch_instance(
    label: str,
    models: list[str],
    key_path: str,
    config: VultrConfig,
) -> tuple[str, str, str]:
    """
    Full lifecycle for one instance: create → wait for IP → wait for SSH → write model file.

    Returns (label, instance_id, ip).
    """
    print(f"  [{label}] Creating instance for: {', '.join(models)}")
    instance_id = create_instance(label, config)
    print(f"  [{label}] Created: {instance_id} — waiting for IP...")

    ip = wait_for_ip(instance_id)
    print(f"  [{label}] Active at {ip} — waiting for SSH...")

    wait_for_ssh(ip)
    print(f"  [{label}] SSH ready — writing model assignment...")

    write_model_file(ip, models, key_path)
    print(f"  [{label}] ✓ Models written. Instance is running headlessly.")

    return label, instance_id, ip


def distribute_models(models: list[str], count: int) -> list[list[str]]:
    """
    Distribute models across N instances using round-robin assignment.

    Examples:
      9 models, 3 instances → [[m0,m3,m6], [m1,m4,m7], [m2,m5,m8]]
      3 models, 5 instances → [[m0], [m1], [m2], [], []]
    """
    buckets: list[list[str]] = [[] for _ in range(count)]
    for i, model in enumerate(models):
        buckets[i % count].append(model)
    return buckets


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Launch self-orchestrating Vultr benchmark instances",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run a model on a single instance
  uv run scripts/orchestrate_vultr.py --models anthropic/claude-opus-4.5

  # Distribute 30 models across 10 instances (3 models each)
  uv run scripts/orchestrate_vultr.py --count 10 --models model1 model2 ... model30
        """,
    )
    parser.add_argument("--models", nargs="+", required=True, help="Model IDs to benchmark")
    parser.add_argument(
        "--count",
        type=int,
        default=1,
        help="Number of instances; models distributed round-robin (default: 1)",
    )
    parser.add_argument(
        "--workers", type=int, default=10, help="Parallel workers for instance setup (default: 10)"
    )
    parser.add_argument(
        "--key",
        default="~/.ssh/id_ed25519",
        help="Path to SSH private key (default: ~/.ssh/id_ed25519)",
    )
    parser.add_argument("--region", default="atl")
    parser.add_argument("--plan", default="vc2-1c-2gb")
    parser.add_argument("--snapshot", default=DEFAULT_SNAPSHOT)
    parser.add_argument("--ssh-keys", default="a4b8f6d9-fa2e-48a4-b12d-b6162d065e52")

    args = parser.parse_args()

    config = VultrConfig(
        region=args.region,
        plan=args.plan,
        snapshot=args.snapshot,
        ssh_keys=args.ssh_keys,
    )

    buckets = distribute_models(args.models, args.count)
    non_empty = [(i, b) for i, b in enumerate(buckets) if b]

    print(f"\n{'=' * 60}")
    print(f"Vultr Benchmark Launcher")
    print(f"{'=' * 60}")
    print(f"Models:    {len(args.models)}")
    print(f"Instances: {args.count} ({len(non_empty)} with models assigned)")
    print(f"Note: laptop must stay online ~90s while instances boot")
    print(f"{'=' * 60}\n")

    created: list[tuple[str, str, str, list[str]]] = []
    failed: list[tuple[str, str]] = []

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(launch_instance, f"bench-{i:02d}", bucket, args.key, config): (
                i,
                bucket,
            )
            for i, bucket in non_empty
        }
        for future in as_completed(futures):
            i, bucket = futures[future]
            label = f"bench-{i:02d}"
            try:
                lbl, instance_id, ip = future.result()
                created.append((lbl, instance_id, ip, bucket))
            except Exception as e:
                print(f"  ✗ {label} failed: {e}", file=sys.stderr)
                failed.append((label, str(e)))

    print(f"\n{'=' * 60}")
    print(f"Summary")
    print(f"{'=' * 60}")
    print(f"Launched: {len(created)}/{len(non_empty)}")

    for label, iid, ip, models in sorted(created):
        print(f"  {label} ({iid}) @ {ip}")
        for m in models:
            print(f"    - {m}")

    if failed:
        print(f"\nFailed ({len(failed)}):")
        for label, err in failed:
            print(f"  {label}: {err}")

    print(f"\nInstances are running headlessly and will self-destruct when done.")
    print(f"Monitor: vultr instance list")
    print(f"Logs:    ssh root@<ip> tail -f /var/log/bench-runner.log")
    print(f"{'=' * 60}\n")

    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
