# Orca recipe `resume`: wake the sandbox and print fresh SSH details (the address changes).
# Everything it needs comes from the lifecycle JSON on stdin, which holds what create returned.

require_tools boat jq ssh ssh-keygen
read_lifecycle
id="$LIFECYCLE_ID"
[ -n "$LIFECYCLE_ROOT" ] || die "the lifecycle payload has no project root; this sandbox was not made by this recipe"

log "resuming $id"
boat_quiet resume "$id" --no-auto-stop --json || exit 1
wait_for_state "$id" 300 'ready|idle|running' || exit 1

resolve_endpoint "$id" || exit 1
pin_host_key "$id" "$SSH_HOST" "$SSH_PORT" || exit 1
retry 10 3 ssh_remote true </dev/null || die "cannot reach $SSH_HOST:$SSH_PORT over SSH"
if [ "$GH_WRAPPER" = true ]; then
  install_gh_wrapper ||
    log "warning: could not install the gh wrapper; Orca's PR actions fail with HTTP 401 once boat's GitHub token expires"
fi
wait_hydrated "$id" 60

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
