# Orca recipe `suspend`: stop the sandbox. Billing pauses and the disk is kept for 14 days.

require_tools boat jq ssh-keygen
read_lifecycle
id="$LIFECYCLE_ID"

if resolve_endpoint "$id" 2>/dev/null; then
  stale_host="$SSH_HOST"
  stale_port="$SSH_PORT"
else
  stale_host=""
  stale_port=""
fi

log "stopping $id"
boat_quiet stop "$id" --json || exit 1
wait_for_state "$id" 900 'stopped|archived' || exit 1

# The next resume gets a new address and host key.
if [ -n "$stale_host" ]; then forget_host "$stale_host" "$stale_port"; fi
log "$id is stopped"
