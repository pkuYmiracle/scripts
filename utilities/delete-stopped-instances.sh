vultr instance list -o json \
  | jq -r '.instances[] | select(.power_status == "stopped") | .id' \
  | xargs -I {} vultr instance delete {}