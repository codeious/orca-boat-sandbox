# Orca recipe `create` (checkoutMode: provisioned-root): boot a fresh boat.dev sandbox, make the
# checkout Orca asked for, run the repo's setupScript if it has one, and print the SSH connection.
#
# Orca passes ORCA_REPO_URL, ORCA_REPO_REF, ORCA_REPO_REF_HEAD and ORCA_REPO_BRANCH. If the boat
# environment already clones the repo, that clone is reused; if not, the repo is cloned here once
# the sandbox has its GitHub login.

remote_checkout_script() {
  cat <<'REMOTE'
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

step() { printf '\n==> %s\n' "$*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

wait_for_boat_clone() {
  # The environment's own clone can land a little after "ready". Never start a second clone on top.
  local i
  for i in $(seq 1 "${CLONE_WAIT_TRIES:-40}"); do
    if [ -d "$PROJECT_ROOT/.git" ] && git -C "$PROJECT_ROOT" rev-parse --verify -q HEAD >/dev/null; then
      return 0
    fi
    [ "$i" -eq 1 ] && echo "waiting for boat to clone $REPO_SLUG into $PROJECT_ROOT" >&2
    sleep 3
  done
  return 1
}

checkout_repo() {
  if [ "$ENV_CLONES_REPO" = 1 ]; then
    wait_for_boat_clone || echo "warning: boat's clone of $REPO_SLUG never appeared; cloning it here" >&2
  fi

  if [ ! -d "$PROJECT_ROOT/.git" ]; then
    [ ! -e "$PROJECT_ROOT" ] || [ -z "$(ls -A "$PROJECT_ROOT" 2>/dev/null)" ] ||
      fail "$PROJECT_ROOT exists and is not a git checkout; not touching it"
    [ "$GITHUB_READY" = 1 ] ||
      fail "$REPO_SLUG is not on the sandbox and its GitHub login did not appear; connect GitHub in the boat dashboard"
    step "cloning $REPO_SLUG"
    git clone --no-checkout "$REPO_URL" "$PROJECT_ROOT"
  fi
  cd "$PROJECT_ROOT"

  # boat's own clone can carry a GitHub token in its origin URL, which keeps fetch and push working
  # before the sandbox login is back. Keep that origin when it is the same repo; never print it.
  current="$(git config --get remote.origin.url 2>/dev/null |
    sed -E 's#^https://([^@/]*@)?github\.com/##; s#\.git$##; s#/$##' || true)"
  if [ -z "$current" ]; then
    git remote add origin "$REPO_URL"
  elif [ "$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO_SLUG" | tr '[:upper:]' '[:lower:]')" ]; then
    git remote set-url origin "$REPO_URL"
  fi

  if gh auth status >/dev/null 2>&1; then gh auth setup-git; fi
  step "fetching $REPO_REF"
  # git can echo the remote URL in its errors, and that URL may hold a token, so its output is dropped.
  if ! git fetch -q origin "$REPO_REF" >/dev/null 2>&1; then
    echo "warning: git fetch failed (the sandbox's GitHub login is probably not back yet); using what is already here" >&2
  fi
  git cat-file -e "${REPO_HEAD}^{commit}" 2>/dev/null ||
    fail "commit ${REPO_HEAD} is not in the sandbox checkout and could not be fetched; connect GitHub in the boat dashboard"
  git checkout -q -B "$REPO_BRANCH" "$REPO_HEAD"
}

run_setup_script() {
  [ -n "$SETUP_SCRIPT" ] || return 0
  [ -f "$SETUP_SCRIPT" ] ||
    fail "setupScript '$SETUP_SCRIPT' (from $SETUP_SCRIPT_SRC) is not in the checkout at ${REPO_HEAD:0:12}"
  step "setup script: $SETUP_SCRIPT"
  bash -l -- "./$SETUP_SCRIPT" </dev/null ||
    fail "setupScript '$SETUP_SCRIPT' failed (exit $?)"
}

main() {
  : "${PROJECT_ROOT:?}" "${REPO_SLUG:?}" "${REPO_URL:?}" "${REPO_REF:?}" "${REPO_HEAD:?}" \
    "${REPO_BRANCH:?}" "${GITHUB_READY:?}" "${ENV_CLONES_REPO:?}"
  checkout_repo
  run_setup_script
  echo "ready at $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
}

main </dev/null
REMOTE
}

# Prints what the sandbox holds for PROJECT_ROOT: none (no checkout yet), clone (a checkout without
# Orca's pinned commit) or commit (a checkout that already has it).
sandbox_repo_state() {
  {
    emit_exports "PROJECT_ROOT=$PROJECT_ROOT" "REPO_HEAD=$REPO_HEAD"
    cat <<'PROBE'
if ! git -C "$PROJECT_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  echo none
elif git -C "$PROJECT_ROOT" cat-file -e "${REPO_HEAD}^{commit}" 2>/dev/null; then
  echo commit
else
  echo clone
fi
PROBE
  } | ssh_remote 'bash -l -s' 2>/dev/null || echo none
}

require_tools boat jq ssh ssh-keygen git
load_repo_request
load_config
preflight
install_failure_cleanup

# With no environment configured, boat clones into new sandboxes whatever its default environment lists.
clone_env="$ENVIRONMENT"
if [ -z "$clone_env" ]; then clone_env="$(default_environment_name)"; fi
boat_clones=0
if [ -n "$clone_env" ] && env_clones_repo "$clone_env" "$REPO_SLUG"; then
  boat_clones=1
  log "$REPO_SLUG: boat environment '$clone_env' clones it into new sandboxes"
else
  log "$REPO_SLUG: not cloned by a boat environment, so it is cloned here"
fi

new_args=(--type "$MACHINE_TYPE" --no-auto-stop)
if [ -n "$SNAPSHOT" ]; then new_args+=(--from "$SNAPSHOT"); fi
if [ -n "$ENVIRONMENT" ]; then new_args+=(--environment "$ENVIRONMENT"); fi
summary="creating a $MACHINE_TYPE sandbox"
if [ -n "$SNAPSHOT" ]; then summary="$summary from snapshot $SNAPSHOT"; fi
if [ -n "$ENVIRONMENT" ]; then summary="$summary with environment $ENVIRONMENT"; fi
if [ -n "$ORG" ]; then summary="$summary in org $ORG"; fi
log "$summary"
new_sandbox "${new_args[@]}" || exit 1
log "sandbox $SANDBOX_ID is ready"

resolve_endpoint "$SANDBOX_ID" || exit 1
pin_host_key "$SANDBOX_ID" "$SSH_HOST" "$SSH_PORT" || exit 1
retry 10 3 ssh_remote true </dev/null || die "cannot reach $SSH_HOST:$SSH_PORT over SSH"
if [ "$GH_WRAPPER" = true ]; then
  install_gh_wrapper ||
    log "warning: could not install the gh wrapper; Orca's PR actions fail with HTTP 401 once boat's GitHub token expires"
fi

wait_hydrated "$SANDBOX_ID" 120

# boat's own clone does not need the sandbox's GitHub login, which can take minutes or never appear.
# When Orca's pinned commit is already there, only give the login a short grace period so the
# fetch can still refresh the remote refs; otherwise the login is the only way to get the commit.
repo_state=none
clone_deadline=$((SECONDS + 60))
while :; do
  repo_state="$(sandbox_repo_state)"
  [ "$repo_state" = none ] || break
  [ "$boat_clones" = 1 ] && [ "$SECONDS" -lt "$clone_deadline" ] || break
  sleep 3
done
if [ "$repo_state" = commit ]; then
  github_wait=20
  log "pinned commit is already on the sandbox; waiting at most ${github_wait}s for GitHub to refresh refs"
else
  github_wait=240
fi
github_ready=1
wait_github_access "$github_wait" "$REPO_HTTPS_URL" || github_ready=0
{
  emit_exports "PROJECT_ROOT=$PROJECT_ROOT" "REPO_SLUG=$REPO_SLUG" "REPO_URL=$REPO_HTTPS_URL" \
    "REPO_REF=$REPO_REF" "REPO_HEAD=$REPO_HEAD" "REPO_BRANCH=$REPO_BRANCH" \
    "GITHUB_READY=$github_ready" "ENV_CLONES_REPO=$boat_clones" \
    "SETUP_SCRIPT=$SETUP_SCRIPT" "SETUP_SCRIPT_SRC=$SETUP_SCRIPT_SRC"
  remote_checkout_script
} | ssh_remote 'bash -l -s' >&2 || {
  rc=$?
  if [ "$github_ready" = 0 ]; then
    log "hint: no GitHub login reached the sandbox. In a boat org whose sandboxes are shared, boat keeps your personal logins off them; put the repo in a boat environment so boat clones it, or see Troubleshooting in the plugin README"
  fi
  exit "$rc"
}

emit_ssh_result "$SANDBOX_ID" "$PROJECT_ROOT"
