# Orca recipe `resume`: wake the sandbox and print fresh SSH details (the address changes).
# Everything it needs comes from the lifecycle JSON on stdin, which holds what create returned.

require_tools boat jq ssh ssh-keygen
read_lifecycle
id="$LIFECYCLE_ID"
[ -n "$LIFECYCLE_ROOT" ] || die "the lifecycle payload has no project root; this sandbox was not made by this recipe"

try_resume() { # id wait_seconds
  if boat_quiet resume "$1" --no-auto-stop --json && wait_for_state "$1" "$2" 'ready|idle|running'; then
    return 0
  fi
  return 1
}

stop_then_resume() { # id [--force]
  boat_quiet stop "$1" ${2:+"$2"} --json && wait_for_state "$1" "${ORCA_BOAT_STOP_WAIT:-900}" 'stopped|archived' &&
    try_resume "$1" 300
}

# Steps that keep the disk come first: a power cycle (which boat refuses on bare metal), then a
# normal stop, which boat can take minutes to finish. Only with recovery set to snapshot do the
# steps that go back to the latest snapshot follow: a forced stop, then a fork. The old sandbox is
# never deleted, and no trap here deletes the fork.
if [ -z "$RECOVERY" ]; then legacy_recovery; fi
log "resuming $id"
if ! try_resume "$id" 300; then
  recovered=0
  if [ "$(machine_provider "$id")" = baremetal ]; then
    log "recovery: $id is on a bare-metal machine, which boat cannot power-cycle; skipping boat recover"
  else
    log "recovery: $id would not resume; power-cycling it with boat recover"
    if boat_quiet recover "$id" --json && try_resume "$id" 180; then
      recovered=1
      log "recovery: $id is back after a power cycle; its disk was not touched"
    fi
  fi
  if [ "$recovered" = 0 ]; then
    log "recovery: stopping $id and starting it again; a normal stop keeps its disk"
    if stop_then_resume "$id"; then
      recovered=1
      log "recovery: $id is back after a stop; its disk was not touched"
    fi
  fi
  if [ "$recovered" = 0 ]; then
    [ "$RECOVERY" = snapshot ] ||
      die "boat cannot resume $id. To recover it from its latest snapshot, set recovery to snapshot (see Recovering an unrecoverable sandbox in the plugin README), or run orca-boat fix"
    log "recovery: force-stopping $id. Changes on its disk made after its latest snapshot are lost"
    if stop_then_resume "$id" --force; then
      recovered=1
      log "recovery: $id is back after a forced stop, at its latest snapshot"
    fi
  fi
  if [ "$recovered" = 0 ]; then
    log "recovery: forking the latest snapshot of $id. Changes on its disk made after that snapshot are not on the fork"
    fork_sandbox "$id" || die "recovery failed: could not fork $id from its latest snapshot"
    [ -n "$SANDBOX_ID" ] && [ "$SANDBOX_ID" != "$id" ] || die "recovery failed: boat did not report a new sandbox for the fork of $id"
    stuck_id="$id"
    id="$SANDBOX_ID"
    trap 'rc=$?; [ "$rc" -eq 0 ] || log "warning: the fork $id is running but Orca does not know it yet; use it, or delete it with boat delete $id"; exit "$rc"' EXIT
    stuck_delete="boat delete $stuck_id"
    if [ -n "$ORG" ]; then stuck_delete="boat --org $ORG delete $stuck_id"; fi
    log "recovery: forked $stuck_id into $id, which Orca now uses. $stuck_id is kept; once you are sure nothing in it is needed, delete it with: $stuck_delete"
    wait_for_state "$id" 300 'ready|idle|running' || exit 1
  fi
fi

resolve_endpoint "$id" || exit 1
pin_host_key "$id" "$SSH_HOST" "$SSH_PORT" || exit 1
retry 10 3 ssh_remote true </dev/null || die "cannot reach $SSH_HOST:$SSH_PORT over SSH"
if [ "$GH_WRAPPER" = true ]; then
  install_gh_wrapper ||
    log "warning: could not install the gh wrapper; Orca's PR actions fail with HTTP 401 once boat's GitHub token expires"
fi
wait_hydrated "$id" 60
# Before Orca connects: a restarted sandbox has a new machine ID, and Orca's server on it the old one.
# bash -s, not -l: a login profile could print to stdout. The last line is the verdict.
machine_id="$({
  machine_id_record_script
  machine_id_restore_script
  echo restore_machine_id
} | ssh_remote 'bash -s' | tail -n 1 || true)"
case "$machine_id" in
  same | none) ;;
  restored) log "put back the machine ID Orca's server on the sandbox belongs to; boat had changed it" ;;
  failed) log "warning: boat changed the sandbox's machine ID and it could not be put back; Orca may report orcad_identity_mismatch" ;;
  unknown) log "warning: the sandbox's machine ID matches none Orca's server could belong to; if Orca reports orcad_identity_mismatch, see Troubleshooting in the plugin README" ;;
  *) log "warning: could not check the sandbox's machine ID" ;;
esac
# A server that died with the previous boot leaves its lock behind, and the next one will not start.
orcad_locks="$({
  orcad_repair_script
  echo repair_orcad_locks
  echo kick_orcad_unit
} | ssh_remote 'bash -s' | tail -n 1 || true)"
case "$orcad_locks" in
  '' | 0) ;;
  *[!0-9]*) log "warning: could not check Orca's server locks on the sandbox" ;;
  *) log "moved $orcad_locks stale Orca server lock(s) to ~/.orca-recovery; they belonged to a server that is gone" ;;
esac
# Puts back the git identity from create if the sandbox has lost it; one it has wins.
if [ -n "$GIT_NAME" ]; then
  { git_identity_script; echo set_git_identity; } | ssh_remote 'bash -l -s' >&2 ||
    log "warning: could not check the git identity on the sandbox"
fi

# The checkout's origin names the repo to probe. boat rewrites origin with a token in it on every
# start, so only the owner/name leaves the sandbox, never the URL.
# The heredoc lives in a function because bash 3.2 cannot parse one inside $( ).
resume_probe() {
  emit_exports "ROOT=$LIFECYCLE_ROOT"
  cat <<'PROBE'
url="$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null)" || exit 0
slug="$(printf '%s' "$url" | sed -E 's#^https://([^@/]*@)?github\.com/##; s#\.git$##; s#/$##')"
case "$slug" in
  */*/* | */ | /* | *[!A-Za-z0-9._/-]*) ;;
  */*) printf '%s' "$slug" ;;
esac
PROBE
}
resume_slug="$(resume_probe | ssh_remote 'bash -l -s' 2>/dev/null || true)"
if [ -n "$resume_slug" ]; then
  # The checkout is intact, so a missing login only blocks fetch and push. Do not hold the workspace
  # hostage for the minutes it can take; boat restores the login on its own.
  wait_github_access 30 "https://github.com/$resume_slug.git" || true
else
  log "no github.com origin in $LIFECYCLE_ROOT; not waiting for the GitHub login"
fi

emit_ssh_result "$id" "$LIFECYCLE_ROOT"
