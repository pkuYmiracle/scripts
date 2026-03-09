# Vultr CLI Reference for AI Agents

This file documents the exact `vultr-cli` commands used in this project so that
AI coding assistants do not hallucinate incorrect flag names.

The binary is `vultr` (alias for `vultr-cli`). Output format is controlled by
`-o`/`--output` (text | json | yaml); scripts use `--output json`.

---

## Snapshots

### Create a snapshot from a running instance
```
vultr snapshot create -i <instance-id> -d "<description>"
```
Flags:
- `-i`, `--id string`          — ID of the instance to snapshot (**not** `--instance-id`)
- `-d`, `--description string` — (optional) description of snapshot contents

### List snapshots
```
vultr snapshot list
vultr snapshot list --output json
```

### Get a snapshot
```
vultr snapshot get <snapshot-id>
vultr snapshot get <snapshot-id> --output json
```

### Delete a snapshot
```
vultr snapshot delete <snapshot-id>
# alias: destroy
```

---

## Instances

### Create an instance from a snapshot
```
vultr instance create \
  --region <region-id> \
  --plan <plan-id> \
  --snapshot <snapshot-id> \
  --ssh-keys "<key-id>[,<key-id>]" \
  --label "<label>" \
  --output json
```
Key flags:
- `-r`, `--region string`    — region ID (e.g. `atl`, `ewr`)
- `-p`, `--plan string`      — plan ID (e.g. `vc2-1c-2gb`)
- `--snapshot string`        — snapshot ID (mutually exclusive with `--os`, `--iso`, `--app`, `--image`)
- `-s`, `--ssh-keys strings` — comma-separated SSH key IDs
- `-l`, `--label string`     — human-readable label
- `-u`, `--userdata string`  — plain-text user-data (blocked for snapshot-based instances)
- `--script-id string`       — startup script ID (blocked for snapshot-based instances)

### List instances
```
vultr instance list
vultr instance list --output json
```

### Get instance details
```
vultr instance get <instance-id>
vultr instance get <instance-id> --output json
```
Returned JSON fields used by `orchestrate_vultr.py`:
- `status`        — `active` | `pending`
- `power_status`  — `running` | `stopped`
- `server_status` — e.g. `ok`, `locked`
- `main_ip`       — assigned IPv4 address (`0.0.0.0` until assigned)

### Start / stop / delete an instance
```
vultr instance start  <instance-id>
vultr instance stop   <instance-id>
vultr instance delete <instance-id>   # alias: destroy
```

---

## Typical snapshot workflow

```bash
# 1. Bootstrap and configure an instance, then capture it:
vultr snapshot create -i <instance-id> -d "bench-runner $(date +%Y-%m-%d)"

# 2. Record the new snapshot ID, update in:
#      orchestrate_vultr.py  → DEFAULT_SNAPSHOT
#      create_instance.sh    → --snapshot flag

# 3. Clean up the bootstrap instance:
vultr instance delete <instance-id>
```
