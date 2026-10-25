# shellcheck shell=bash disable=SC2034
# Helpers for the Boat.dev sandbox recipe. build.mjs copies the functions each phase calls into that
# phase's command, so: keep every statement below the variable block inside a function, open a
# function with `name() {` on its own line (or write it on one line), and call it by its plain name.
# Bash 3.2 is the floor: it is the macOS system bash.
#
# stdout carries only the final JSON object (create, resume). Logs and errors go to stderr.

set -euo pipefail

# Orca starts recipe commands from the desktop app, whose PATH is minimal.
export PATH="$HOME/.ascii/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export BOAT_NO_UPDATE=true

KNOWN_HOSTS="${ORCA_BOAT_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
USER_CONFIG="${ORCA_BOAT_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/orca-boat/config.json}"
REPO_CONFIG_NAME=".orca-boat.json"
SETTING_KEYS="org environment snapshot machineType setupScript ghWrapper sshUser identityFile"
LOCAL_ONLY_KEYS="sshUser identityFile"
# jq: the user file's entry for this repo, matched without regard to case.
# shellcheck disable=SC2016 # $r is a jq variable
USER_REPO_ENTRY='[(.repos // {}) | to_entries[] | select(.key | ascii_downcase == ($r | ascii_downcase)) | .value][0]'
ORG_RE='^[A-Za-z0-9][A-Za-z0-9._ -]*$'
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
SSH_USER_RE='^[A-Za-z_][A-Za-z0-9._-]*$'

REPO_SLUG=""
REPO_NAME=""
REPO_HTTPS_URL=""
REPO_REF=""
REPO_HEAD=""
REPO_BRANCH=""
PROJECT_ROOT=""
REPO_CONFIG=""
ENV_LIST=""
SETTING_VALUE=""
SETTING_SOURCE=""
LIFECYCLE_ID=""
LIFECYCLE_ROOT=""

ORG=""
ENVIRONMENT=""
SNAPSHOT=""
MACHINE_TYPE=default
SETUP_SCRIPT=""
GH_WRAPPER=true
SSH_USER=user
IDENTITY_FILE="$HOME/.ssh/ascii_box_ed25519"
ORG_SRC=""
ENVIRONMENT_SRC=""
SNAPSHOT_SRC=""
MACHINE_TYPE_SRC=""
SETUP_SCRIPT_SRC=""
GH_WRAPPER_SRC=""
SSH_USER_SRC=""
IDENTITY_FILE_SRC=""

SANDBOX_ID=""
SSH_HOST=""
SSH_PORT=""
GIT_NAME=""
GIT_EMAIL=""

log() { printf '[boat] %s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

require_tools() { # tool...
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH; the plugin README lists what to install"
  done
}

# --- configuration ---------------------------------------------------------------------------
# Highest layer first: ORCA_BOAT_* environment, the user file's repos["owner/name"], the repo's
# .orca-boat.json, the user file's defaults, then the built-in default.

# Names the keys in a config file that this recipe does not know, so a typo does not pass silently.
unknown_config_keys() { # file kind
  jq -r --arg known "$SETTING_KEYS" --arg kind "$2" '
    ($known | split(" ")) as $k
    | if $kind == "repo" then (keys - $k - ["$schema"])[]
      else
        (keys - ["defaults", "repos", "$schema"])[],
        ((.defaults // {}) | keys - $k | map("defaults." + .))[],
        ((.repos // {}) | to_entries[] | .key as $r | (.value | keys - $k | map("repos[" + $r + "]." + .))[])
      end' "$1"
}

check_config_file() { # file kind(user|repo)
  local file="$1" kind="$2" key unknown
  [ -f "$file" ] || return 0
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || die "$file is not valid JSON, or is not a JSON object"
  if [ "$kind" = user ]; then
    jq -e '((.defaults // {}) | type == "object")
      and ((.repos // {}) | type == "object" and all(.[]; type == "object"))' "$file" >/dev/null 2>&1 ||
      die "$file: \"defaults\" and each entry of \"repos\" must be JSON objects"
  else
    for key in $LOCAL_ONLY_KEYS; do
      if jq -e --arg k "$key" 'has($k)' "$file" >/dev/null 2>&1; then
        die "$file sets $key, which is a local setting and not allowed in a repo file; set it in $USER_CONFIG"
      fi
    done
  fi
  unknown="$(unknown_config_keys "$file" "$kind" | tr '\n' ' ')"
  [ -z "$unknown" ] || log "warning: ignoring unknown keys in $file: $unknown"
}

# Prints the value of a key from the object a jq expression selects in a config file; nothing when unset.
config_get() { # file selector key
  [ -f "$1" ] || return 0
  jq -r --arg r "$REPO_SLUG" --arg k "$3" "($2) | objects | .[\$k] | select(. != null) | tostring" "$1"
}

# Sets SETTING_VALUE and SETTING_SOURCE from the highest layer that sets the key.
resolve_setting() { # key ENV_NAME fallback
  local key="$1" envname="$2" value
  value="${!envname:-}"
  if [ -n "$value" ]; then
    SETTING_VALUE="$value"
    SETTING_SOURCE="$envname"
    return 0
  fi
  value="$(config_get "$USER_CONFIG" "$USER_REPO_ENTRY" "$key")"
  if [ -n "$value" ]; then
    SETTING_VALUE="$value"
    SETTING_SOURCE="$USER_CONFIG, repos[\"$REPO_SLUG\"]"
    return 0
  fi
  value="$(config_get "$REPO_CONFIG" . "$key")"
  if [ -n "$value" ]; then
    SETTING_VALUE="$value"
    SETTING_SOURCE="$REPO_CONFIG"
    return 0
  fi
  value="$(config_get "$USER_CONFIG" .defaults "$key")"
  if [ -n "$value" ]; then
    SETTING_VALUE="$value"
    SETTING_SOURCE="$USER_CONFIG, defaults"
    return 0
  fi
  SETTING_VALUE="$3"
  SETTING_SOURCE="built-in default"
}

load_setting() { # VAR key ENV_NAME fallback
  resolve_setting "$2" "$3" "$4"
  printf -v "$1" '%s' "$SETTING_VALUE"
  printf -v "${1}_SRC" '%s' "$SETTING_SOURCE"
  if [ -n "$SETTING_VALUE" ] && [ "$SETTING_SOURCE" != "built-in default" ]; then
    log "config: $2 = $SETTING_VALUE (from $SETTING_SOURCE)"
  fi
}

require_match() { # key value source regex hint
  [ -z "$2" ] || [[ "$2" =~ $4 ]] || die "invalid $1 '$2' (from $3): $5"
}

check_setup_script() {
  local path="$SETUP_SCRIPT"
  [ -n "$path" ] || return 0
  path="${path#./}"
  case "$path" in
    /* | -*) path="" ;;
  esac
  case "/$path/" in
    */../* | */./* | *//*) path="" ;;
  esac
  [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    die "invalid setupScript '$SETUP_SCRIPT' (from $SETUP_SCRIPT_SRC): use a path inside the repo, such as scripts/boat-setup.sh"
  SETUP_SCRIPT="$path"
}

validate_settings() {
  require_match org "$ORG" "$ORG_SRC" "$ORG_RE" "use an organization name or id from: boat org list"
  require_match environment "$ENVIRONMENT" "$ENVIRONMENT_SRC" "$NAME_RE" "use letters, digits, dots, dashes and underscores"
  require_match snapshot "$SNAPSHOT" "$SNAPSHOT_SRC" "$NAME_RE" "use a snapshot name or a bsh_ share code"
  require_match sshUser "$SSH_USER" "$SSH_USER_SRC" "$SSH_USER_RE" "not a valid user name"
  case "$MACHINE_TYPE" in
    small | default | large | xlarge) ;;
    *) die "invalid machineType '$MACHINE_TYPE' (from $MACHINE_TYPE_SRC): use small, default, large or xlarge" ;;
  esac
  case "$GH_WRAPPER" in
    true | false) ;;
    *) die "invalid ghWrapper '$GH_WRAPPER' (from $GH_WRAPPER_SRC): use true or false" ;;
  esac
  case "$IDENTITY_FILE" in
    '' | -* | *$'\n'*) die "invalid identityFile '$IDENTITY_FILE' (from $IDENTITY_FILE_SRC)" ;;
  esac
  check_setup_script
}

# Needs REPO_SLUG. The repo file is read from the checkout Orca ran the recipe for.
load_config() {
  REPO_CONFIG="${ORCA_REPO_PATH:-$PWD}/$REPO_CONFIG_NAME"
  check_config_file "$USER_CONFIG" user
  check_config_file "$REPO_CONFIG" repo
  load_setting ORG org ORCA_BOAT_ORG ""
  load_setting ENVIRONMENT environment ORCA_BOAT_ENVIRONMENT ""
  load_setting SNAPSHOT snapshot ORCA_BOAT_SNAPSHOT ""
  load_setting MACHINE_TYPE machineType ORCA_BOAT_MACHINE_TYPE default
  load_setting SETUP_SCRIPT setupScript ORCA_BOAT_SETUP_SCRIPT ""
  load_setting GH_WRAPPER ghWrapper ORCA_BOAT_GH_WRAPPER true
  load_setting SSH_USER sshUser ORCA_BOAT_SSH_USER user
  load_setting IDENTITY_FILE identityFile ORCA_BOAT_IDENTITY_FILE "$HOME/.ssh/ascii_box_ed25519"
  IDENTITY_FILE="${IDENTITY_FILE/#\~/$HOME}"
  validate_settings
}

# --- the repo Orca asks for (provisioned-root) -----------------------------------------------

# Sets the REPO_* variables and PROJECT_ROOT from the checkout Orca wants (ORCA_REPO_*). The sandbox
# only has a GitHub login, so the remote becomes https and other hosts are refused. Errors never echo
# the URL, because a remote can carry a token.
load_repo_request() {
  local url path owner
  [ "${ORCA_RECIPE_RESULT_SCHEMA_VERSION:-}" = 2 ] ||
    die "this recipe needs a newer Orca: it did not get ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 (update to 1.4.199 or later)"
  url="${ORCA_REPO_URL:-}"
  REPO_REF="${ORCA_REPO_REF:-}"
  REPO_HEAD="${ORCA_REPO_REF_HEAD:-}"
  REPO_BRANCH="${ORCA_REPO_BRANCH:-}"
  if [ -z "$url" ] || [ -z "$REPO_REF" ] || [ -z "$REPO_BRANCH" ]; then
    die "Orca did not pass ORCA_REPO_URL, ORCA_REPO_REF and ORCA_REPO_BRANCH"
  fi
  [[ "$REPO_HEAD" =~ ^[0-9a-f]{40}$ ]] || die "ORCA_REPO_REF_HEAD is not a full lowercase commit id"
  case "$REPO_REF" in -* | *[[:space:]]*) die "unsafe ref from Orca" ;; esac
  case "$REPO_BRANCH" in -* | *[[:space:]]*) die "unsafe branch name from Orca" ;; esac
  git check-ref-format --allow-onelevel "$REPO_REF" 2>/dev/null || die "ORCA_REPO_REF is not a valid ref name"
  git check-ref-format --branch "$REPO_BRANCH" >/dev/null 2>&1 || die "ORCA_REPO_BRANCH is not a valid branch name"

  case "$url" in
    git@github.com:*) path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    https://github.com/*) path="${url#https://github.com/}" ;;
    *) die "the repo remote is not a plain github.com URL; boat sandboxes only have a GitHub login" ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  owner="${path%%/*}"
  REPO_NAME="${path#*/}"
  case "$path" in */*/* | */) die "unexpected GitHub path in the repo remote" ;; esac
  case "$owner" in '' | *[!A-Za-z0-9._-]*) die "unexpected GitHub owner in the repo remote" ;; esac
  case "$REPO_NAME" in '' | . | .. | *[!A-Za-z0-9._-]*) die "unexpected GitHub repo name in the repo remote" ;; esac
  [ "$owner" != "$path" ] || die "unexpected GitHub path in the repo remote"
  REPO_SLUG="$owner/$REPO_NAME"
  REPO_HTTPS_URL="https://github.com/$REPO_SLUG.git"
  PROJECT_ROOT="/home/user/$REPO_NAME"
}

# --- boat ------------------------------------------------------------------------------------

# Every boat call that touches sandboxes, environments or snapshots runs in the configured org.
boat_cli() {
  if [ -n "$ORG" ]; then boat --org "$ORG" "$@"; else boat "$@"; fi
}

# boat's JSON for stop and resume carries the sandbox's address, URL and creator name; Orca keeps
# the recipe log, so show it only when the command fails.
boat_quiet() { # subcommand args...
  local out
  out="$(boat_cli "$@" 2>&1)" || {
    log "boat $1 failed: $out"
    return 1
  }
}

missing_setting() { # key value source env_name detail
  die "boat has no $1 '$2' ($5). It came from: $3.
  Fix it there, or override it with $4=<value>, or in $USER_CONFIG under repos[\"$REPO_SLUG\"]."
}

named_snapshot_status() { # name -> absent | unknown | <status>
  boat_cli snapshots --json 2>/dev/null | jq -r --arg n "$1" '
    [.named[]? | select(.name == $n)]
    | if length == 0 then "absent" else (.[0].status // .[0].state // "present") end' 2>/dev/null ||
    printf 'unknown'
}

default_environment_name() {
  [ -n "$ENV_LIST" ] || return 0
  printf '%s' "$ENV_LIST" | jq -r '[.environments[]? | select(.isDefault == true) | .name][0] // empty' 2>/dev/null || true
}

# True when the boat environment clones this repo into every new sandbox.
env_clones_repo() { # environment owner/name
  boat_cli env info "$1" --json 2>/dev/null | jq -e --arg r "$2" '
    any(.environment.selectedRepositories[]?; (.fullName | ascii_downcase) == ($r | ascii_downcase))' >/dev/null 2>&1
}

# Fails early, before anything is billed, when boat is not usable or a configured name does not
# exist. A boat call that cannot be read only warns: the real call fails with boat's own error.
preflight() {
  local out state names status
  out="$(boat status --json 2>/dev/null || true)"
  state="$(printf '%s' "$out" | jq -r '.account.loginState // empty' 2>/dev/null || true)"
  if [ -z "$state" ]; then
    log "warning: could not read the boat login state; continuing"
  elif [ "$state" != active ]; then
    die "you are not logged in to boat (state: $state); run: boat login"
  fi

  if [ -n "$ORG" ]; then
    out="$(boat org list --json 2>/dev/null || true)"
    names="$(printf '%s' "$out" | jq -r '[.orgs[]?.name] | join(", ")' 2>/dev/null || true)"
    if [ -z "$names" ]; then
      log "warning: could not list your boat organizations; continuing"
    elif ! printf '%s' "$out" | jq -e --arg o "$ORG" '
      any(.orgs[]; .id == $o or ((.name // "") | ascii_downcase) == ($o | ascii_downcase))' >/dev/null 2>&1; then
      missing_setting org "$ORG" "$ORG_SRC" ORCA_BOAT_ORG "your organizations: $names"
    fi
  fi

  ENV_LIST="$(boat_cli env list --json 2>/dev/null || true)"
  if [ -n "$ENVIRONMENT" ]; then
    if ! printf '%s' "$ENV_LIST" | jq -e '.environments | type == "array"' >/dev/null 2>&1; then
      log "warning: could not list boat environments; continuing"
    elif ! printf '%s' "$ENV_LIST" | jq -e --arg n "$ENVIRONMENT" 'any(.environments[]; .name == $n)' >/dev/null 2>&1; then
      names="$(printf '%s' "$ENV_LIST" | jq -r '[.environments[].name] | join(", ")')"
      missing_setting environment "$ENVIRONMENT" "$ENVIRONMENT_SRC" ORCA_BOAT_ENVIRONMENT "environments: $names"
    fi
  fi

  # A share code cannot be listed, so it is passed to boat as is.
  if [ -n "$SNAPSHOT" ]; then
    case "$SNAPSHOT" in
      bsh_*) ;;
      *)
        status="$(named_snapshot_status "$SNAPSHOT")"
        case "$status" in
          absent) missing_setting snapshot "$SNAPSHOT" "$SNAPSHOT_SRC" ORCA_BOAT_SNAPSHOT "see: boat snapshots" ;;
          unknown) log "warning: could not list named snapshots; continuing" ;;
          ready | completed | present) ;;
          *) log "warning: named snapshot '$SNAPSHOT' has status '$status'" ;;
        esac
        ;;
    esac
  fi
}

# --- sandbox lifecycle -----------------------------------------------------------------------

# Creates a sandbox and sets SANDBOX_ID as soon as it is known, so a failure can still clean up.
new_sandbox() { # boat new flags...
  local events rc=0 err
  events="$(mktemp "${TMPDIR:-/tmp}/boat-new.XXXXXX")"
  boat_cli new --json "$@" >"$events" || rc=$?
  SANDBOX_ID="$(jq -rs '[.[] | objects | (.id // .sandbox.id // empty)
    | select(type == "string" and startswith("bx_"))] | first // empty' "$events" 2>/dev/null || true)"
  if [ "$rc" -ne 0 ] || ! jq -es 'any(.[]; type == "object" and .event == "ready")' "$events" >/dev/null 2>&1; then
    err="$(jq -rs '[.[] | objects | select(.event == "error") | (.error // .message)] | last // empty' \
      "$events" 2>/dev/null || true)"
    log "boat new failed (exit $rc): ${err:-no error event}"
    rm -f "$events"
    return 1
  fi
  rm -f "$events"
}

delete_sandbox() { # id
  local out rc=0
  out="$(boat_cli delete "$1" --yes --json 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if printf '%s' "$out" | grep -qiE 'not_found|not found|404'; then
    log "sandbox $1 is already gone"
    return 0
  fi
  log "boat delete $1 failed: $out"
  return 1
}

# EXIT trap: delete the sandbox this script created when the script fails.
on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ -n "$SANDBOX_ID" ] && [ "${ORCA_BOAT_KEEP_ON_ERROR:-}" != 1 ]; then
    log "cleaning up sandbox $SANDBOX_ID after failure"
    delete_sandbox "$SANDBOX_ID" || true
    # The pin for a deleted sandbox would otherwise stay in known_hosts for good.
    if [ -n "${SSH_HOST:-}" ] && [ -n "${SSH_PORT:-}" ]; then forget_host "$SSH_HOST" "$SSH_PORT" || true; fi
  fi
  exit "$rc"
}

install_failure_cleanup() {
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

sandbox_state() { # id
  boat_cli info "$1" --json 2>/dev/null | jq -r '.sandbox.state // empty' 2>/dev/null || true
}

wait_for_state() { # id timeout_seconds state_regex
  local id="$1" deadline state re
  re="^($3)\$"
  deadline=$((SECONDS + $2))
  while :; do
    state="$(sandbox_state "$id")"
    if [[ "$state" =~ $re ]]; then return 0; fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "timed out after ${2}s waiting for $id to be $3 (last state: ${state:-unknown})"
      return 1
    fi
    sleep 3
  done
}

# Waits for the background file restore. Never fatal: files are readable while it runs.
wait_hydrated() { # id timeout_seconds
  local id="$1" deadline hydrated
  deadline=$((SECONDS + $2))
  while :; do
    hydrated="$(boat_cli info "$id" --json 2>/dev/null | jq -r '.sandbox.hydrated // empty' 2>/dev/null || true)"
    if [ "$hydrated" = true ]; then return 0; fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "$id is still restoring files after ${2}s; continuing"
      return 0
    fi
    sleep 3
  done
}

# Boat restores the GitHub login (GITHUB_TOKEN, gh hosts.yml) on a resumed sandbox anywhere from
# 0 to several minutes after it reports ready, and `hydrated` is already true by then. Probes git
# itself, because `gh auth status` can exit non-zero while git already works. A new sandbox has the
# gh login but no git credential helper until `gh auth setup-git` runs, so the probe runs it first.
# Non-fatal: without the login the sandbox still runs, but git fetch and push fail.
wait_github_access() { # timeout_seconds https_repo_url
  local started=$SECONDS deadline=$((SECONDS + $1))
  while :; do
    if {
      emit_exports "REPO_URL=$2"
      echo 'if gh auth status >/dev/null 2>&1; then gh auth setup-git >/dev/null 2>&1; fi'
      # shellcheck disable=SC2016 # expands on the sandbox, from the export line above
      echo 'GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$REPO_URL" HEAD >/dev/null 2>&1'
    } | ssh_remote 'bash -l -s'; then
      log "GitHub access is ready after $((SECONDS - started))s"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "warning: git cannot reach GitHub from the sandbox after ${1}s (no usable GitHub login); git fetch and push will fail"
      return 1
    fi
    sleep 3
  done
}

# Puts the gh wrapper at /usr/bin/gh and the real binary at /usr/bin/gh.real, so a process that
# started hours ago and holds an expired GITHUB_TOKEN (Orca's relay daemon) still reaches GitHub
# through the login boat keeps in hosts.yml. It has to be /usr/bin/gh because the relay runs that
# path directly. dpkg-divert keeps `apt upgrade gh` from overwriting the wrapper. The files live on
# the sandbox disk, so they survive suspend. Safe to re-run.
install_gh_wrapper() {
  ssh_remote 'bash -s' >&2 <<'REMOTE'
set -euo pipefail
real=/usr/bin/gh.real
if [ ! -x "$real" ]; then
  [ -x /usr/bin/gh ] || { echo "gh is not at /usr/bin/gh; not installing the wrapper" >&2; exit 3; }
  if dpkg -S /usr/bin/gh >/dev/null 2>&1; then
    sudo -n dpkg-divert --local --rename --divert "$real" --add /usr/bin/gh >/dev/null </dev/null
  else
    sudo -n mv /usr/bin/gh "$real" </dev/null
  fi
fi
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<'ORCA_GH_WRAPPER'
@@gh-wrapper.sh@@
ORCA_GH_WRAPPER
sudo -n install -m 0755 "$tmp" /usr/bin/gh </dev/null
REMOTE
}

retry() { # attempts delay_seconds command...
  local attempts="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    [ "$n" -lt "$attempts" ] || return 1
    n=$((n + 1))
    sleep "$delay"
  done
}

# --- addressing and SSH ----------------------------------------------------------------------

# Sets SSH_HOST and SSH_PORT. sshEndpoint (host:port) is set when the sandbox has no public IPv4.
resolve_endpoint() { # id
  local info endpoint
  info="$(boat_cli info "$1" --json)" || return 1
  endpoint="$(printf '%s' "$info" | jq -r '.sandbox.sshEndpoint // empty')"
  if [ -n "$endpoint" ]; then
    SSH_HOST="${endpoint%:*}"
    SSH_PORT="${endpoint##*:}"
  else
    SSH_HOST="$(printf '%s' "$info" | jq -r '.sandbox.ip // empty')"
    SSH_PORT=22
  fi
  if [ -z "$SSH_HOST" ]; then
    log "sandbox $1 has no reachable address"
    return 1
  fi
  case "$SSH_PORT" in
    '' | *[!0-9]*)
      log "unexpected SSH port '$SSH_PORT' for $1"
      return 1
      ;;
  esac
}

known_hosts_name() { # host port
  if [ "$2" = 22 ]; then printf '%s' "$1"; else printf '[%s]:%s' "$1" "$2"; fi
}

lock_known_hosts() {
  local tries=0
  mkdir -p "$(dirname "$KNOWN_HOSTS")"
  until mkdir "$KNOWN_HOSTS.boat-lock" 2>/dev/null; do
    tries=$((tries + 1))
    # A lock held this long belongs to a script that died.
    if [ "$tries" -ge 100 ]; then rmdir "$KNOWN_HOSTS.boat-lock" 2>/dev/null || true; fi
    sleep 0.2
  done
}

unlock_known_hosts() { rmdir "$KNOWN_HOSTS.boat-lock" 2>/dev/null || true; }

forget_host() { # host port
  [ -f "$KNOWN_HOSTS" ] || return 0
  lock_known_hosts
  ssh-keygen -R "$(known_hosts_name "$1" "$2")" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
  unlock_known_hosts
}

pin_known_host() { # host port "ssh-ed25519 AAAA..."
  lock_known_hosts
  touch "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
  ssh-keygen -R "$(known_hosts_name "$1" "$2")" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
  if [ -s "$KNOWN_HOSTS" ] && [ -n "$(tail -c 1 "$KNOWN_HOSTS")" ]; then printf '\n' >>"$KNOWN_HOSTS"; fi
  printf '%s %s\n' "$(known_hosts_name "$1" "$2")" "$3" >>"$KNOWN_HOSTS"
  unlock_known_hosts
}

sha256_hex() { # stdin -> hex digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    openssl dgst -sha256 | awk '{ print $NF }'
  fi
}

# `boat ssh` stores the host key it received from the boat API in
# ~/.ssh/ascii_sandbox_known_hosts/<first 24 hex of sha256(sandbox id)>, as
# "ascii-sandbox-<name> ssh-ed25519 <key>", and refreshes it after every resume.
boat_pinned_host_key() { # id
  local file
  file="$HOME/.ssh/ascii_sandbox_known_hosts/$(printf '%s' "$1" | sha256_hex | cut -c1-24)"
  [ -f "$file" ] || return 1
  awk 'NF >= 3 { print $2 " " $3; exit }' "$file"
}

# Authorizes the boat CLI key on the sandbox and pins the sandbox's host key in known_hosts.
# The key comes from the boat API, not from SSH, so the first connection is not trust-on-first-use.
# A wrong key only makes the strict SSH check fail; it can never make Orca trust an unknown host.
pin_host_key() { # id host port
  local key
  retry 10 3 boat_cli ssh "$1" true >&2 || {
    log "could not authorize the boat SSH key on $1"
    return 1
  }
  [ -f "$IDENTITY_FILE" ] || {
    log "SSH identity $IDENTITY_FILE is missing"
    return 1
  }
  key="$(boat_pinned_host_key "$1")" || key=""
  case "$key" in
    ssh-ed25519\ ?*) ;;
    *)
      log "boat did not record an ed25519 host key for $1"
      return 1
      ;;
  esac
  pin_known_host "$2" "$3" "$key"
}

# Runs a command on the sandbox with the same target, identity and known_hosts Orca will use.
ssh_remote() { # remote command; stdin is forwarded
  ssh -p "$SSH_PORT" -i "$IDENTITY_FILE" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=20 \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
    "$SSH_USER@$SSH_HOST" "$@"
}

# Prints `export KEY='value'` lines so values reach a remote script on stdin, never on a command line.
emit_exports() { # KEY=value...
  local kv
  for kv in "$@"; do
    printf 'export %s=%q\n' "${kv%%=*}" "${kv#*=}"
  done
}

# --- git identity ----------------------------------------------------------------------------

# True when both are safe to hand to git config: no control characters or angle brackets, and an
# email of the form a@b without spaces.
valid_git_identity() { # name email
  [ -n "$1" ] && [ "$(printf '%s%s' "$1" "$2" | LC_ALL=C tr -d '\000-\037\177<>')" = "$1$2" ] || return 1
  case "$2" in *[[:space:]]* | @* | *@ | *@*@*) return 1 ;; *@*) return 0 ;; *) return 1 ;; esac
}

# Sets GIT_NAME and GIT_EMAIL to the identity git uses for this repo on this machine, so commits
# made on the sandbox carry the same author.
load_git_identity() {
  local dir="${ORCA_REPO_PATH:-$PWD}" out name email
  out="$(git -C "$dir" config --show-origin --get user.name 2>/dev/null || true)"
  name="${out#*$'\t'}"
  email="$(git -C "$dir" config --get user.email 2>/dev/null || true)"
  if valid_git_identity "$name" "$email"; then
    GIT_NAME="$name"
    GIT_EMAIL="$email"
    log "git identity: $name (user.name from ${out%%$'\t'*})"
  else
    log "warning: no usable git user.name and user.email for $dir here; to commit on the sandbox, set them there"
  fi
}

# Prints a sandbox function, set_git_identity, that sets git's user.name and user.email from GIT_NAME
# and GIT_EMAIL where neither the global nor the system git config has one. It never fails.
git_identity_script() {
  emit_exports "GIT_NAME=$GIT_NAME" "GIT_EMAIL=$GIT_EMAIL"
  cat <<'GITID'
git_id() { git config --global --get "user.$1" >/dev/null || git config --system --get "user.$1" >/dev/null || git config --global "user.$1" "$2" || echo "warning: could not set git user.$1" >&2; }
set_git_identity() { if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then git_id name "$GIT_NAME"; git_id email "$GIT_EMAIL"; fi; }
GITID
}

# --- Orca contract ---------------------------------------------------------------------------

# Orca owns the checkout in provisioned-root mode, so every result is schema 2 with that mode.
# userData is all a later suspend, resume or destroy knows about this sandbox: the project path,
# and the org, gh wrapper choice and git identity it was created with.
emit_ssh_result() { # id project_root
  jq -cn --arg id "$1" --arg root "$2" --arg host "$SSH_HOST" --argjson port "$SSH_PORT" \
    --arg user "$SSH_USER" --arg identity "$IDENTITY_FILE" --arg org "$ORG" --argjson gh "$GH_WRAPPER" \
    --arg gn "$GIT_NAME" --arg ge "$GIT_EMAIL" '{
      schemaVersion: 2,
      checkoutMode: "provisioned-root",
      connection: {
        type: "ssh",
        projectRoot: $root,
        target: {
          label: ("boat-" + $id),
          host: $host,
          port: $port,
          username: $user,
          identityFile: $identity,
          identitiesOnly: true
        }
      },
      userData: ({provider: "boat", resourceId: $id, projectRoot: $root, ghWrapper: $gh}
        + (if $org == "" then {} else {org: $org} end)
        + (if $gn == "" then {} else {gitName: $gn, gitEmail: $ge} end))
    }'
}

# Reads the lifecycle JSON Orca writes to stdin and sets LIFECYCLE_ID, LIFECYCLE_ROOT, ORG,
# SSH_USER, IDENTITY_FILE, GH_WRAPPER, GIT_NAME and GIT_EMAIL to what the sandbox was created with.
read_lifecycle() {
  local payload id root org user identity name email
  payload="$(cat)"
  id="$(printf '%s' "$payload" | jq -r '.recipeResult.userData.resourceId // empty')"
  [ -n "$id" ] || die "no resource id in the lifecycle payload"
  case "$id" in
    bx_[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;;
    *) die "unexpected resource id in the lifecycle payload: $id" ;;
  esac
  root="$(printf '%s' "$payload" |
    jq -r '.recipeResult.userData.projectRoot // .recipeResult.connection.projectRoot // empty')"
  [[ -z "$root" || "$root" =~ ^/home/user/[A-Za-z0-9._-]+$ ]] ||
    die "unexpected project root in the lifecycle payload"
  org="$(printf '%s' "$payload" | jq -r '.recipeResult.userData.org // empty')"
  user="$(printf '%s' "$payload" | jq -r '.recipeResult.connection.target.username // empty')"
  identity="$(printf '%s' "$payload" | jq -r '.recipeResult.connection.target.identityFile // empty')"
  require_match org "$org" "the lifecycle payload" "$ORG_RE" "not a valid organization"
  require_match sshUser "$user" "the lifecycle payload" "$SSH_USER_RE" "not a valid user name"
  case "$identity" in -* | *$'\n'*) die "unexpected identity file in the lifecycle payload" ;; esac
  LIFECYCLE_ID="$id"
  LIFECYCLE_ROOT="$root"
  ORG="$org"
  if [ -n "$user" ]; then SSH_USER="$user"; fi
  if [ -n "$identity" ]; then IDENTITY_FILE="$identity"; fi
  GH_WRAPPER="$(printf '%s' "$payload" |
    jq -r 'if .recipeResult.userData.ghWrapper == false then "false" else "true" end')"
  name="$(printf '%s' "$payload" | jq -r '.recipeResult.userData.gitName // empty')"
  email="$(printf '%s' "$payload" | jq -r '.recipeResult.userData.gitEmail // empty')"
  if valid_git_identity "$name" "$email"; then
    GIT_NAME="$name"
    GIT_EMAIL="$email"
  elif [ -n "$name$email" ]; then
    log "warning: ignoring an unusable git identity in the lifecycle payload"
  fi
}
