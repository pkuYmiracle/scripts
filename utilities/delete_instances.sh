#!/bin/bash

set -euo pipefail

usage() {
  cat <<EOF
Usage:
  $0 <instance-id> [instance-id ...]
  $0 --stopped

Options:
  --stopped   Delete all instances with power_status="stopped"
  -h, --help  Show this help message
EOF
}

delete_ids=()
delete_stopped=false

while (($# > 0)); do
  case "$1" in
    --stopped)
      delete_stopped=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      delete_ids+=("$1")
      shift
      ;;
  esac
done

if [ "$delete_stopped" = true ] && [ ${#delete_ids[@]} -gt 0 ]; then
  echo "Cannot combine --stopped with explicit instance IDs"
  usage
  exit 1
fi

if [ "$delete_stopped" = true ]; then
  mapfile -t delete_ids < <(
    vultr instance list --output json \
      | jq -r '.instances[] | select(.power_status == "stopped") | .id'
  )

  if [ ${#delete_ids[@]} -eq 0 ]; then
    echo "No stopped instances found"
    exit 0
  fi
fi

if [ ${#delete_ids[@]} -eq 0 ]; then
  usage
  exit 1
fi

for id in "${delete_ids[@]}"; do
  echo "Deleting instance $id..."
  vultr instance delete "$id"
done
