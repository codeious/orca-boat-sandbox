# Orca recipe `destroy`: delete the sandbox and its disk for good.

require_tools boat jq ssh-keygen
read_lifecycle
id="$LIFECYCLE_ID"

if resolve_endpoint "$id" 2>/dev/null; then forget_host "$SSH_HOST" "$SSH_PORT"; fi

log "deleting $id"
delete_sandbox "$id" || exit 1
