#!/usr/bin/env bash
# Free tests: no network and no boat account. boat is a stub (test/stubs/boat), HOME is a temp dir.
# Covers config precedence, what a repo file may set, repo URL checks, preflight, lifecycle parsing,
# failure cleanup, and the generated recipe commands run the way Orca runs them (`sh -c`, stdin).
#
#   bash test/config-test.sh
# shellcheck disable=SC2016 # the snippets handed to lib_eval expand in the child shell, not here
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
REPO_DIR="$TMP/repo"
STUB_DIR="$TMP/stub"
LOG="$TMP/boat.log"
CONFIG_DIR="$HOME_DIR/.config/orca-boat"
USER_FILE="$CONFIG_DIR/config.json"
REPO_FILE="$REPO_DIR/.orca-boat.json"
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)")"
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"

passed=0
failed=0
OUT="" ERR="" RC=0 EXTRA_ENV="" STDIN_FILE=/dev/null

pass() {
  passed=$((passed + 1))
  printf 'ok   %s\n' "$1"
}
fail() {
  failed=$((failed + 1))
  printf 'FAIL %s\n     %s\n' "$1" "$2"
}
expect_eq() { # name want got
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$2', got '$3'"; fi
}
expect_has() { # name haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing '$3' in: $2" ;; esac
}
expect_lacks() { # name haystack needle
  case "$2" in *"$3"*) fail "$1" "unexpected '$3' in: $2" ;; *) pass "$1" ;; esac
}
expect_ok() { if [ "$RC" -eq 0 ]; then pass "$1"; else fail "$1" "exit $RC: $ERR"; fi; }
expect_fails() { if [ "$RC" -ne 0 ]; then pass "$1"; else fail "$1" "expected a failure, got exit 0"; fi; }

reset() {
  rm -rf "$HOME_DIR" "$REPO_DIR" "$STUB_DIR"
  mkdir -p "$CONFIG_DIR" "$REPO_DIR" "$STUB_DIR" "$HOME_DIR/.ascii/bin" "$HOME_DIR/.ssh"
  # lib.sh puts $HOME/.ascii/bin first on PATH, so the stub wins over any real boat.
  cp "$ROOT/test/stubs/boat" "$ROOT/test/stubs/ssh" "$HOME_DIR/.ascii/bin/"
  chmod +x "$HOME_DIR/.ascii/bin/boat" "$HOME_DIR/.ascii/bin/ssh"
  : >"$LOG"
  EXTRA_ENV=""
  STDIN_FILE=/dev/null
}
user_cfg() { printf '%s' "$1" >"$USER_FILE"; }
repo_cfg() { printf '%s' "$1" >"$REPO_FILE"; }
fixture() { printf '%s\n' "$2" >"$STUB_DIR/$1"; }

# Runs a snippet with src/lib.sh sourced, in a clean environment. Sets OUT (stdout), ERR, RC.
lib_eval() {
  local errf="$TMP/err"
  RC=0
  # shellcheck disable=SC2086 # EXTRA_ENV is a list of VAR=value words
  OUT="$(env -i PATH="$BASE_PATH" HOME="$HOME_DIR" ORCA_REPO_PATH="$REPO_DIR" \
    BOAT_STUB_DIR="$STUB_DIR" BOAT_STUB_LOG="$LOG" $EXTRA_ENV \
    bash -c '. "$1"; eval "$2"' _ "$ROOT/src/lib.sh" "$1" <"$STDIN_FILE" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf")"
}

# Runs one generated recipe command exactly as Orca does: `sh -c "<command>"` with stdin attached.
run_recipe() { # phase
  local errf="$TMP/err" command
  command="$(jq -r --arg p "$1" '.[$p]' "$ROOT/recipes/boat-sandbox.json")"
  RC=0
  # shellcheck disable=SC2086 # EXTRA_ENV is a list of VAR=value words
  OUT="$(env -i PATH="$BASE_PATH" HOME="$HOME_DIR" ORCA_REPO_PATH="$REPO_DIR" \
    BOAT_STUB_DIR="$STUB_DIR" BOAT_STUB_LOG="$LOG" $EXTRA_ENV \
    sh -c "$command" <"$STDIN_FILE" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf")"
}

load_values='REPO_SLUG=acme/widgets; load_config
  printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$ORG" "$ENVIRONMENT" "$SNAPSHOT" "$MACHINE_TYPE" "$SETUP_SCRIPT" "$GH_WRAPPER" "$SSH_USER" "$IDENTITY_FILE"'
DEFAULT_KEY="$HOME_DIR/.ssh/ascii_box_ed25519"

# --- precedence -------------------------------------------------------------------------------
reset
lib_eval "$load_values"
expect_eq "built-in defaults" "|||default||true|user|$DEFAULT_KEY" "$OUT"
expect_eq "built-in defaults log nothing" "" "$ERR"

reset
user_cfg '{"defaults":{"machineType":"xlarge"}}'
lib_eval "$load_values"
expect_has "layer 4: user defaults apply" "$OUT" "|xlarge|"
expect_has "layer 4 is named in the log" "$ERR" "machineType = xlarge (from $USER_FILE, defaults)"

repo_cfg '{"machineType":"small","environment":"team-env"}'
lib_eval "$load_values"
expect_has "layer 3: repo file beats user defaults" "$OUT" "|team-env|"
expect_has "layer 3 value" "$OUT" "|small|"
expect_has "layer 3 is named in the log" "$ERR" "machineType = small (from $REPO_FILE)"

user_cfg '{"defaults":{"machineType":"xlarge"},"repos":{"Acme/Widgets":{"machineType":"large"}}}'
lib_eval "$load_values"
expect_has "layer 2: user repo entry beats repo file, any letter case" "$OUT" "|large|"
expect_has "layer 2 is named in the log" "$ERR" "(from $USER_FILE, repos[\"acme/widgets\"])"
expect_has "layer 2 leaves other repo-file keys alone" "$OUT" "|team-env|"

EXTRA_ENV="ORCA_BOAT_MACHINE_TYPE=small ORCA_BOAT_ORG=Acme"
lib_eval "$load_values"
expect_has "layer 1: environment beats the user repo entry" "$OUT" "|small|"
expect_has "layer 1 sets org" "$OUT" "Acme|"
expect_has "layer 1 is named in the log" "$ERR" "machineType = small (from ORCA_BOAT_MACHINE_TYPE)"

reset
user_cfg '{"repos":{"other/repo":{"machineType":"large"}}}'
lib_eval "$load_values"
expect_has "a user entry for another repo is ignored" "$OUT" "|default|"

reset
user_cfg '{"defaults":{"sshUser":"dev","identityFile":"~/keys/id"}}'
lib_eval "$load_values"
expect_has "sshUser comes from user defaults" "$OUT" "|dev|"
expect_has "identityFile expands ~" "$OUT" "|$HOME_DIR/keys/id"

reset
repo_cfg '{"ghWrapper":false,"setupScript":"./scripts/boat-setup.sh","snapshot":"bsh_abc123","org":"Acme"}'
lib_eval "$load_values"
expect_eq "false and normalized setupScript from the repo file" \
  "Acme||bsh_abc123|default|scripts/boat-setup.sh|false|user|$DEFAULT_KEY" "$OUT"

# --- the shipped schema and example match the library ---------------------------------------------
reset
lib_eval 'for k in $SETTING_KEYS; do case " $LOCAL_ONLY_KEYS " in *" $k "*) ;; *) echo "$k" ;; esac; done | sort | tr "\n" " "'
expect_eq "schema lists exactly the settings a repo file may set" "$OUT" \
  "$(jq -r '.properties | keys - ["$schema"] | sort | join(" ")' "$ROOT/schema/orca-boat.schema.json") "

reset
cp "$ROOT/examples/.orca-boat.json" "$REPO_FILE"
lib_eval "$load_values"
expect_ok "the example .orca-boat.json loads"
expect_lacks "the example .orca-boat.json has no unknown keys" "$ERR" "unknown keys"
expect_has "the example names its setup script" "$OUT" "|scripts/boat-setup.sh|"

# --- what a repo file may not set, and bad values -----------------------------------------------
reset
repo_cfg '{"sshUser":"root"}'
lib_eval "$load_values"
expect_fails "repo file cannot set sshUser"
expect_has "sshUser error names the file to use" "$ERR" "set it in $USER_FILE"

reset
repo_cfg '{"identityFile":"~/.ssh/id_rsa"}'
lib_eval "$load_values"
expect_fails "repo file cannot set identityFile"

reset
repo_cfg '{"machineType":"huge"}'
lib_eval "$load_values"
expect_fails "invalid machineType fails"
expect_has "invalid machineType names its source" "$ERR" "(from $REPO_FILE)"

reset
repo_cfg '{"ghWrapper":"yes"}'
lib_eval "$load_values"
expect_fails "ghWrapper must be true or false"

for bad in '../x.sh' '/etc/passwd' '-rf' 'a/../b.sh' 'a//b.sh' 'a/./b.sh' 'has space.sh' 'semi;colon.sh'; do
  reset
  repo_cfg "{\"setupScript\":\"$bad\"}"
  lib_eval "$load_values"
  expect_fails "setupScript '$bad' is refused"
done

for field in org environment snapshot; do
  reset
  repo_cfg "{\"$field\":\"bad;value\"}"
  lib_eval "$load_values"
  expect_fails "$field with shell characters is refused"
done

reset
repo_cfg '{"snapshott":"typo"}'
lib_eval "$load_values"
expect_ok "an unknown key does not fail"
expect_has "an unknown key is reported" "$ERR" "ignoring unknown keys in $REPO_FILE: snapshott"

reset
user_cfg '{"defaults":{"nope":1},"repos":{"a/b":{"nah":1}}}'
lib_eval "$load_values"
expect_has "unknown user keys are reported with their path" "$ERR" "defaults.nope"
expect_has "unknown user repo keys are reported with their path" "$ERR" "repos[a/b].nah"

reset
repo_cfg '{not json'
lib_eval "$load_values"
expect_fails "invalid JSON fails"
reset
repo_cfg '["a"]'
lib_eval "$load_values"
expect_fails "a JSON array is not a config"
reset
user_cfg '{"repos":{"a/b":"string"}}'
lib_eval "$load_values"
expect_fails "a user repo entry must be an object"

# --- the repo Orca asks for ----------------------------------------------------------------------
repo_env="ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 ORCA_REPO_REF=main ORCA_REPO_BRANCH=feature/x ORCA_REPO_REF_HEAD=$HEAD_SHA"
parse_repo='load_repo_request; printf "%s|%s|%s|%s\n" "$REPO_SLUG" "$REPO_HTTPS_URL" "$PROJECT_ROOT" "$REPO_BRANCH"'
for url in 'git@github.com:Acme/widgets.git' 'ssh://git@github.com/Acme/widgets.git' \
  'https://github.com/Acme/widgets' 'https://github.com/Acme/widgets.git/'; do
  reset
  EXTRA_ENV="$repo_env ORCA_REPO_URL=$url"
  lib_eval "$parse_repo"
  expect_eq "repo URL $url" "Acme/widgets|https://github.com/Acme/widgets.git|/home/user/widgets|feature/x" "$OUT"
done

for url in 'git@gitlab.com:a/b.git' 'https://github.com/a/b/c' 'https://github.com/a' 'https://github.com/a/..' \
  'https://github.com/a/b%20c' 'file:///tmp/x'; do
  reset
  EXTRA_ENV="$repo_env ORCA_REPO_URL=$url"
  lib_eval "$parse_repo"
  expect_fails "repo URL $url is refused"
done

reset
EXTRA_ENV="$repo_env ORCA_REPO_URL=https://x-access-token:SECRETTOKEN@github.com/a/b.git"
lib_eval "$parse_repo"
expect_fails "a URL with credentials is refused"
expect_lacks "a refused URL is never echoed" "$ERR$OUT" "SECRETTOKEN"

reset
EXTRA_ENV="ORCA_REPO_REF=main ORCA_REPO_BRANCH=x ORCA_REPO_REF_HEAD=$HEAD_SHA ORCA_REPO_URL=git@github.com:a/b.git"
lib_eval "$parse_repo"
expect_fails "an Orca without the provisioned-root contract is refused"
expect_has "...and told to update" "$ERR" "1.4.199"

reset
EXTRA_ENV="ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 ORCA_REPO_REF=main ORCA_REPO_BRANCH=-x ORCA_REPO_REF_HEAD=$HEAD_SHA ORCA_REPO_URL=git@github.com:a/b.git"
lib_eval "$parse_repo"
expect_fails "a branch starting with - is refused"

reset
EXTRA_ENV="ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 ORCA_REPO_REF=main ORCA_REPO_BRANCH=x ORCA_REPO_REF_HEAD=abc123 ORCA_REPO_URL=git@github.com:a/b.git"
lib_eval "$parse_repo"
expect_fails "a short commit id is refused"

# --- boat calls and --org ------------------------------------------------------------------------
reset
lib_eval 'ORG=""; boat_cli info bx_ab12cd34 --json >/dev/null || true'
expect_eq "no --org without an org" "info bx_ab12cd34 --json" "$(cat "$LOG")"
: >"$LOG"
lib_eval 'ORG="Code ious"; boat_cli info bx_ab12cd34 --json >/dev/null || true'
expect_eq "--org is passed as one argument when an org is set" "--org Code ious info bx_ab12cd34 --json" "$(cat "$LOG")"

# --- preflight -----------------------------------------------------------------------------------
fixture_boat() {
  fixture status.json '{"account":{"loginState":"active"}}'
  fixture org-list.json '{"active":"Personal","orgs":[{"id":"org_1","name":"Personal"},{"id":"org_2","name":"Acme"}]}'
  fixture env-list.json '{"environments":[{"name":"base","isDefault":true,"selectedRepositories":[]},{"name":"team-env","isDefault":false,"selectedRepositories":[{"fullName":"acme/widgets"}]}]}'
  fixture snapshots.json '{"named":[{"name":"team-snapshot","status":"ready"},{"name":"half-made","status":"saving"}]}'
}
run_preflight='REPO_SLUG=acme/widgets; load_config; preflight; echo preflight-ok'

reset
fixture_boat
fixture status.json '{"account":{"loginState":"signed out"}}'
lib_eval "$run_preflight"
expect_fails "preflight: signed out"
expect_has "preflight: signed out says how to log in" "$ERR" "boat login"

reset
fixture_boat
lib_eval "$run_preflight"
expect_eq "preflight: nothing configured passes" "preflight-ok" "$OUT"
expect_lacks "preflight: nothing configured makes no --org call" "$(cat "$LOG")" "--org"

reset
fixture_boat
rm "$STUB_DIR/status.json"
lib_eval "$run_preflight"
expect_ok "preflight: an unreadable login state only warns"
expect_has "preflight: ...and says so" "$ERR" "could not read the boat login state"

reset
fixture_boat
EXTRA_ENV="ORCA_BOAT_ORG=nope"
lib_eval "$run_preflight"
expect_fails "preflight: unknown org"
expect_has "preflight: unknown org lists the real ones" "$ERR" "Personal, Acme"
expect_has "preflight: unknown org names where it came from" "$ERR" "ORCA_BOAT_ORG"

reset
fixture_boat
EXTRA_ENV="ORCA_BOAT_ORG=acme"
lib_eval "$run_preflight"
expect_eq "preflight: org matches without regard to case" "preflight-ok" "$OUT"
expect_has "preflight: later calls carry --org" "$(cat "$LOG")" "--org acme env list"

reset
fixture_boat
repo_cfg '{"environment":"orca-missing"}'
lib_eval "$run_preflight"
expect_fails "preflight: unknown environment"
expect_has "preflight: unknown environment names the file" "$ERR" "$REPO_FILE"
expect_has "preflight: unknown environment lists the real ones" "$ERR" "base, team-env"
expect_has "preflight: unknown environment shows the override" "$ERR" "ORCA_BOAT_ENVIRONMENT"

reset
fixture_boat
repo_cfg '{"snapshot":"gone"}'
lib_eval "$run_preflight"
expect_fails "preflight: unknown snapshot"
expect_has "preflight: unknown snapshot names the file" "$ERR" "$REPO_FILE"

reset
fixture_boat
repo_cfg '{"snapshot":"team-snapshot","environment":"team-env"}'
lib_eval "$run_preflight"
expect_eq "preflight: existing snapshot and environment pass" "preflight-ok" "$OUT"

reset
fixture_boat
repo_cfg '{"snapshot":"half-made"}'
lib_eval "$run_preflight"
expect_ok "preflight: a snapshot that is not ready only warns"
expect_has "preflight: ...with its status" "$ERR" "has status 'saving'"

reset
fixture_boat
repo_cfg '{"snapshot":"bsh_abc123"}'
lib_eval "$run_preflight"
expect_eq "preflight: a share code is passed through" "preflight-ok" "$OUT"
expect_lacks "preflight: a share code is not looked up" "$(cat "$LOG")" "snapshots"

reset
fixture_boat
fixture env-info-team-env.json '{"environment":{"name":"team-env","selectedRepositories":[{"fullName":"Acme/Widgets"}]}}'
fixture env-info-base.json '{"environment":{"name":"base","selectedRepositories":[]}}'
lib_eval 'ORG=""; ENV_LIST="$(boat_cli env list --json)"
  echo "default=$(default_environment_name)"
  env_clones_repo team-env acme/widgets && echo clones-yes || echo clones-no
  env_clones_repo team-env other/repo && echo other-yes || echo other-no
  env_clones_repo base acme/widgets && echo base-yes || echo base-no
  env_clones_repo missing acme/widgets && echo missing-yes || echo missing-no'
expect_eq "environment helpers" "default=base
clones-yes
other-no
base-no
missing-no" "$OUT"

# --- creating and deleting sandboxes -------------------------------------------------------------
reset
fixture new.json '{"event":"progress","message":"booting"}
{"event":"created","sandbox":{"id":"bx_ab12cd34"}}
{"event":"ready","sandbox":{"id":"bx_ab12cd34"}}'
lib_eval 'ORG=""; new_sandbox --type default --no-auto-stop; echo "id=$SANDBOX_ID"'
expect_eq "new_sandbox reads the id" "id=bx_ab12cd34" "$OUT"

reset
fixture new.json '{"event":"created","sandbox":{"id":"bx_ab12cd34"}}
{"event":"error","error":"quota exceeded"}'
printf '1' >"$STUB_DIR/new.json.rc"
lib_eval 'ORG=""; new_sandbox --type default || echo "failed id=$SANDBOX_ID"'
expect_eq "new_sandbox keeps the id of a sandbox that failed to get ready" "failed id=bx_ab12cd34" "$OUT"
expect_has "new_sandbox reports boat's error" "$ERR" "quota exceeded"

reset
fixture delete.json '{"event":"deleted"}'
lib_eval 'ORG=""; SANDBOX_ID=bx_ab12cd34; install_failure_cleanup; exit 3'
expect_eq "failure cleanup keeps the exit code" "3" "$RC"
expect_has "failure cleanup deletes the sandbox" "$(cat "$LOG")" "delete bx_ab12cd34 --yes --json"

reset
fixture delete.json '{"event":"deleted"}'
EXTRA_ENV="ORCA_BOAT_KEEP_ON_ERROR=1"
lib_eval 'ORG=""; SANDBOX_ID=bx_ab12cd34; install_failure_cleanup; exit 3'
expect_lacks "ORCA_BOAT_KEEP_ON_ERROR=1 keeps the sandbox" "$(cat "$LOG")" "delete"

reset
fixture delete.json '{"event":"deleted"}'
lib_eval 'ORG=""; SANDBOX_ID=bx_ab12cd34; install_failure_cleanup; exit 0'
expect_lacks "a successful run never deletes" "$(cat "$LOG")" "delete"

# --- Orca contract: result and lifecycle payload -------------------------------------------------
reset
lib_eval 'ORG=""; GH_WRAPPER=true; SSH_HOST=203.0.113.9; SSH_PORT=2222; SSH_USER=user; IDENTITY_FILE=/k/id
  emit_ssh_result bx_ab12cd34 /home/user/widgets'
expect_eq "result shape without an org" "true" "$(printf '%s' "$OUT" | jq '
  .schemaVersion == 2 and .checkoutMode == "provisioned-root" and .connection.type == "ssh"
  and .connection.projectRoot == "/home/user/widgets"
  and .connection.target == {label: "boat-bx_ab12cd34", host: "203.0.113.9", port: 2222, username: "user", identityFile: "/k/id", identitiesOnly: true}
  and .userData == {provider: "boat", resourceId: "bx_ab12cd34", projectRoot: "/home/user/widgets", ghWrapper: true}')"
lib_eval 'ORG=Acme; GH_WRAPPER=false; SSH_HOST=h; SSH_PORT=22; SSH_USER=user; IDENTITY_FILE=/k/id
  emit_ssh_result bx_ab12cd34 /home/user/widgets'
expect_eq "result keeps org and ghWrapper in userData" "true" \
  "$(printf '%s' "$OUT" | jq '.userData.org == "Acme" and .userData.ghWrapper == false')"

payload='{"schemaVersion":1,"recipeResult":{"userData":{"provider":"boat","resourceId":"bx_ab12cd34","projectRoot":"/home/user/widgets","org":"Acme","ghWrapper":false},"connection":{"projectRoot":"/home/user/widgets","target":{"username":"dev","identityFile":"/k/id"}}}}'
read_back='read_lifecycle; printf "%s|%s|%s|%s|%s|%s\n" "$LIFECYCLE_ID" "$LIFECYCLE_ROOT" "$ORG" "$SSH_USER" "$IDENTITY_FILE" "$GH_WRAPPER"'
reset
printf '%s' "$payload" >"$TMP/payload"
STDIN_FILE="$TMP/payload"
lib_eval "$read_back"
expect_eq "lifecycle payload is read back" "bx_ab12cd34|/home/user/widgets|Acme|dev|/k/id|false" "$OUT"

printf '%s' '{"recipeResult":{"userData":{"resourceId":"bx_ab12cd34"}}}' >"$TMP/payload"
lib_eval "$read_back"
expect_eq "a payload without org or target keeps the defaults" "bx_ab12cd34|||user|$DEFAULT_KEY|true" "$OUT"

for bad in 'bx_ABCD1234' 'bx_abc' 'bx_ab12cd34x' '../etc' ''; do
  printf '{"recipeResult":{"userData":{"resourceId":"%s"}}}' "$bad" >"$TMP/payload"
  lib_eval "$read_back"
  expect_fails "lifecycle resource id '$bad' is refused"
done
printf '%s' '{"recipeResult":{"userData":{"resourceId":"bx_ab12cd34","projectRoot":"/etc"}}}' >"$TMP/payload"
lib_eval "$read_back"
expect_fails "lifecycle project root outside /home/user is refused"
printf '%s' '{"recipeResult":{"userData":{"resourceId":"bx_ab12cd34","org":"a;b"}}}' >"$TMP/payload"
lib_eval "$read_back"
expect_fails "lifecycle org with shell characters is refused"

# --- host keys ----------------------------------------------------------------------------------
reset
lib_eval 'KNOWN_HOSTS="$HOME/.ssh/known_hosts"
  pin_known_host 203.0.113.9 22 "ssh-ed25519 AAAAkey1"
  pin_known_host 203.0.113.9 2222 "ssh-ed25519 AAAAkey2"
  pin_known_host 203.0.113.9 22 "ssh-ed25519 AAAAkey3"
  forget_host 203.0.113.9 2222
  cat "$KNOWN_HOSTS"'
expect_eq "known_hosts: pin replaces, forget removes only its port" "203.0.113.9 ssh-ed25519 AAAAkey3" "$OUT"

reset
fingerprint="$(printf '%s' bx_ab12cd34 | shasum -a 256 | cut -c1-24)"
mkdir -p "$HOME_DIR/.ssh/ascii_sandbox_known_hosts"
printf 'ascii-sandbox-x ssh-ed25519 AAAAboatkey\n' >"$HOME_DIR/.ssh/ascii_sandbox_known_hosts/$fingerprint"
lib_eval 'boat_pinned_host_key bx_ab12cd34'
expect_eq "boat's own host key record is found" "ssh-ed25519 AAAAboatkey" "$OUT"

# --- generated recipe commands, run as Orca runs them ---------------------------------------------
hosts_before="203.0.113.9 ssh-ed25519 AAAAgone
198.51.100.7 ssh-ed25519 AAAAkeep"
life='{"recipeResult":{"userData":{"provider":"boat","resourceId":"bx_ab12cd34","projectRoot":"/home/user/widgets","org":"Acme"},"connection":{"target":{"username":"user","identityFile":"/k/id"}}}}'

reset
fixture info.json '{"sandbox":{"state":"stopped","ip":"203.0.113.9"}}'
fixture delete.json '{"event":"deleted"}'
printf '%s\n' "$hosts_before" >"$HOME_DIR/.ssh/known_hosts"
printf '%s' "$life" >"$TMP/payload"
STDIN_FILE="$TMP/payload"
run_recipe destroy
expect_ok "destroy runs under sh -c with stdin"
expect_has "destroy deletes in the org it was created in" "$(cat "$LOG")" "--org Acme delete bx_ab12cd34 --yes --json"
expect_eq "destroy forgets only that host" "198.51.100.7 ssh-ed25519 AAAAkeep" "$(cat "$HOME_DIR/.ssh/known_hosts")"
expect_eq "destroy prints nothing on stdout" "" "$OUT"

reset
fixture info.json '{"sandbox":{"state":"stopped","ip":"203.0.113.9"}}'
fixture stop.json '{"event":"stopped"}'
printf '%s\n' "$hosts_before" >"$HOME_DIR/.ssh/known_hosts"
printf '%s' "$life" >"$TMP/payload"
STDIN_FILE="$TMP/payload"
run_recipe suspend
expect_ok "suspend runs under sh -c with stdin"
expect_has "suspend stops in the org" "$(cat "$LOG")" "--org Acme stop bx_ab12cd34 --json"
expect_eq "suspend forgets the stale host" "198.51.100.7 ssh-ed25519 AAAAkeep" "$(cat "$HOME_DIR/.ssh/known_hosts")"
expect_lacks "suspend keeps boat's stop JSON out of the log" "$ERR" '"event":"stopped"'

reset
fixture info.json '{"sandbox":{"state":"ready","ip":"203.0.113.9"}}'
fixture stop.json '{"error":"stop refused","event":"error"}'
printf '1' >"$STUB_DIR/stop.json.rc"
printf '%s' "$life" >"$TMP/payload"
STDIN_FILE="$TMP/payload"
run_recipe suspend
expect_fails "suspend fails when boat stop fails"
expect_has "...and shows boat's own error" "$ERR" "boat stop failed: {\"error\":\"stop refused\""

reset
printf '%s' '{"recipeResult":{"userData":{}}}' >"$TMP/payload"
STDIN_FILE="$TMP/payload"
run_recipe destroy
expect_fails "destroy without a resource id fails"
expect_eq "...and calls boat not at all" "" "$(cat "$LOG")"

create_env="ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 ORCA_REPO_REF=main ORCA_REPO_BRANCH=feature/x ORCA_REPO_REF_HEAD=$HEAD_SHA"

reset
EXTRA_ENV="$create_env ORCA_REPO_URL=git@gitlab.com:a/b.git"
run_recipe create
expect_fails "create refuses a non-GitHub remote"
expect_eq "...before calling boat at all" "" "$(cat "$LOG")"

reset
fixture_boat
fixture status.json '{"account":{"loginState":"signed out"}}'
EXTRA_ENV="$create_env ORCA_REPO_URL=git@github.com:acme/widgets.git"
run_recipe create
expect_fails "create stops when signed out"
expect_lacks "...without creating a sandbox" "$(cat "$LOG")" "new "

reset
fixture_boat
repo_cfg '{"environment":"orca-missing"}'
EXTRA_ENV="$create_env ORCA_REPO_URL=git@github.com:acme/widgets.git"
run_recipe create
expect_fails "create stops on an unknown environment"
expect_lacks "...without creating a sandbox" "$(cat "$LOG")" "new "
expect_has "...and says which file named it" "$ERR" "$REPO_FILE"
expect_eq "...with nothing on stdout" "" "$OUT"

# --- create and resume end to end, with boat and ssh stubbed ----------------------------------------
# The sandbox is "bx_ab12cd34" at 203.0.113.9. boat's own host-key record and the SSH key exist.
fake_sandbox() {
  fixture_boat
  fixture new.json '{"event":"created","sandbox":{"id":"bx_ab12cd34"}}
{"event":"ready","sandbox":{"id":"bx_ab12cd34"}}'
  fixture info.json '{"sandbox":{"state":"ready","ip":"203.0.113.9","hydrated":true}}'
  fixture env-info-team-env.json '{"environment":{"name":"team-env","selectedRepositories":[{"fullName":"acme/widgets"}]}}'
  fixture env-info-base.json '{"environment":{"name":"base","selectedRepositories":[]}}'
  fixture ssh.json '{"event":"ok"}'
  fixture resume.json '{"event":"resumed"}'
  fixture delete.json '{"event":"deleted"}'
  touch "$HOME_DIR/.ssh/ascii_box_ed25519"
  mkdir -p "$HOME_DIR/.ssh/ascii_sandbox_known_hosts"
  printf 'ascii-sandbox-x ssh-ed25519 AAAAboatkey\n' \
    >"$HOME_DIR/.ssh/ascii_sandbox_known_hosts/$(printf '%s' bx_ab12cd34 | shasum -a 256 | cut -c1-24)"
}
scripts_sent() { cat "$STUB_DIR/ssh-scripts.log" 2>/dev/null || true; }
is_one_json_line() { [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$1" | jq -e . >/dev/null 2>&1; }

reset
fake_sandbox
repo_cfg '{"org":"Acme","environment":"team-env","snapshot":"team-snapshot","machineType":"large","setupScript":"scripts/boat-setup.sh"}'
EXTRA_ENV="$create_env ORCA_REPO_URL=git@github.com:acme/widgets.git"
run_recipe create
expect_ok "create runs end to end"
expect_eq "create prints one JSON line on stdout" "yes" "$(if is_one_json_line "$OUT"; then echo yes; else echo no; fi)"
expect_eq "create result carries the sandbox and the SSH target" "true" "$(printf '%s' "$OUT" | jq --arg key "$DEFAULT_KEY" '
  .schemaVersion == 2 and .checkoutMode == "provisioned-root"
  and .connection.projectRoot == "/home/user/widgets"
  and .connection.target.host == "203.0.113.9" and .connection.target.port == 22
  and .connection.target.username == "user" and .connection.target.identityFile == $key
  and .userData.resourceId == "bx_ab12cd34" and .userData.org == "Acme" and .userData.ghWrapper == true')"
expect_has "create starts the sandbox with every configured setting" "$(cat "$LOG")" \
  "--org Acme new --json --type large --no-auto-stop --from team-snapshot --environment team-env"
expect_has "create authorizes the key in the same org" "$(cat "$LOG")" "--org Acme ssh bx_ab12cd34 true"
expect_eq "create pins boat's host key" "203.0.113.9 ssh-ed25519 AAAAboatkey" "$(cat "$HOME_DIR/.ssh/known_hosts")"
expect_has "create reuses the environment's clone" "$(scripts_sent)" "export ENV_CLONES_REPO=1"
expect_has "create sends the pinned commit" "$(scripts_sent)" "export REPO_HEAD=$HEAD_SHA"
expect_has "create sends the setup script" "$(scripts_sent)" "export SETUP_SCRIPT=scripts/boat-setup.sh"
expect_has "create installs the gh wrapper" "$(scripts_sent)" 'exec /usr/bin/gh.real "$@"'
expect_has "create checks host keys strictly" "$(cat "$STUB_DIR/ssh.log")" "-o StrictHostKeyChecking=yes"
expect_lacks "create never sends a URL with credentials" "$(scripts_sent)" "@github.com"
expect_has "create says where each setting came from" "$ERR" "environment = team-env (from $REPO_FILE)"

reset
fake_sandbox
repo_cfg '{"ghWrapper":false}'
EXTRA_ENV="$create_env ORCA_REPO_URL=git@github.com:acme/widgets.git"
run_recipe create
expect_ok "create with defaults and no gh wrapper"
expect_has "create without settings passes none to boat new" "$(cat "$LOG")" "new --json --type default --no-auto-stop"
expect_lacks "create without an org passes no --org" "$(cat "$LOG")" "--org"
expect_lacks "create skips the gh wrapper when asked" "$(scripts_sent)" "gh.real"
expect_eq "create records ghWrapper=false for later phases" "false" "$(printf '%s' "$OUT" | jq '.userData.ghWrapper')"
expect_eq "create leaves org out of userData" "false" "$(printf '%s' "$OUT" | jq '.userData | has("org")')"

reset
fake_sandbox
repo_cfg '{"setupScript":"scripts/boat-setup.sh"}'
printf '1' >"$STUB_DIR/ssh-checkout.rc"
EXTRA_ENV="$create_env ORCA_REPO_URL=git@github.com:acme/widgets.git"
run_recipe create
expect_fails "create fails when the setup script fails"
expect_eq "...with nothing on stdout" "" "$OUT"
expect_has "...and deletes the sandbox it started" "$(cat "$LOG")" "delete bx_ab12cd34 --yes --json"
expect_eq "...and forgets its host key" "" "$(cat "$HOME_DIR/.ssh/known_hosts")"
expect_lacks "...and gives no GitHub hint when the login was there" "$ERR" "hint:"

# No GitHub login on the sandbox: the pinned commit is already there, so create waits 20s for it.
reset
fake_sandbox
printf '1' >"$STUB_DIR/ssh-github.rc"
printf '1' >"$STUB_DIR/ssh-checkout.rc"
EXTRA_ENV="$create_env ORCA_REPO_URL=git@github.com:acme/widgets.git"
run_recipe create
expect_fails "create fails when the checkout needs a GitHub login that never came"
expect_has "...and warns that git cannot reach GitHub" "$ERR" "git cannot reach GitHub from the sandbox after 20s"
expect_has "...and hints at the environment and org visibility" "$ERR" "hint: git cannot reach GitHub from the sandbox. In our tests an org sandbox got your GitHub login when its boat environment passed GitHub through"
expect_lacks "...without telling the user to connect GitHub in the dashboard" "$ERR" "connect GitHub in the boat dashboard"
expect_has "...and still deletes the sandbox" "$(cat "$LOG")" "delete bx_ab12cd34 --yes --json"

# A new sandbox has the gh login but no git credential helper until `gh auth setup-git` runs.
reset
fake_sandbox
: >"$STUB_DIR/ssh-needs-setup-git"
EXTRA_ENV="$create_env ORCA_REPO_URL=git@github.com:acme/widgets.git"
run_recipe create
expect_ok "create works when git only gets credentials after gh auth setup-git"
expect_has "...the GitHub probe sees access" "$ERR" "GitHub access is ready after"
expect_lacks "...with no warning about GitHub access" "$ERR" "cannot reach GitHub"
expect_eq "...and the sandbox script sets up git before it clones" "yes" "$(scripts_sent | sed -n '/^checkout_repo() {/,/^}/p' |
  awk '/gh auth setup-git/ && !s { s = NR } /git clone/ && !c { c = NR } END { print (s && c && s < c) ? "yes" : "no" }')"

reset
fake_sandbox
printf '1' >"$STUB_DIR/ssh-checkout.rc"
EXTRA_ENV="$create_env ORCA_REPO_URL=git@github.com:acme/widgets.git ORCA_BOAT_KEEP_ON_ERROR=1"
run_recipe create
expect_fails "create still fails with ORCA_BOAT_KEEP_ON_ERROR=1"
expect_lacks "...but keeps the sandbox" "$(cat "$LOG")" "delete"

reset
fake_sandbox
printf '%s' "$life" | jq -c --arg k "$DEFAULT_KEY" '.recipeResult.connection.target.identityFile = $k' >"$TMP/payload"
STDIN_FILE="$TMP/payload"
run_recipe resume
expect_ok "resume runs end to end"
expect_eq "resume prints one JSON line on stdout" "yes" "$(if is_one_json_line "$OUT"; then echo yes; else echo no; fi)"
expect_eq "resume returns the new address with the saved identity" "true" "$(printf '%s' "$OUT" | jq --arg key "$DEFAULT_KEY" '
  .schemaVersion == 2 and .connection.target.host == "203.0.113.9"
  and .connection.target.identityFile == $key and .userData.org == "Acme"
  and .userData.resourceId == "bx_ab12cd34"')"
expect_has "resume wakes the sandbox in its org" "$(cat "$LOG")" "--org Acme resume bx_ab12cd34 --no-auto-stop --json"
expect_has "resume pins the host key" "$(cat "$HOME_DIR/.ssh/known_hosts")" "203.0.113.9 ssh-ed25519 AAAAboatkey"
expect_has "resume reinstalls the gh wrapper by default" "$(scripts_sent)" "gh.real"
expect_lacks "resume keeps boat's resume JSON out of the log" "$ERR" '"event":"resumed"'

reset
fake_sandbox
: >"$STUB_DIR/ssh-needs-setup-git"
printf '%s' "$life" | jq -c --arg k "$DEFAULT_KEY" '.recipeResult.connection.target.identityFile = $k' >"$TMP/payload"
STDIN_FILE="$TMP/payload"
run_recipe resume
expect_ok "resume works when git only gets credentials after gh auth setup-git"
expect_has "...the GitHub probe sees access" "$ERR" "GitHub access is ready after"
expect_lacks "...with no warning about GitHub access" "$ERR" "cannot reach GitHub"

reset
fake_sandbox
printf '1' >"$STUB_DIR/resume.json.rc"
printf '%s' "$life" | jq -c --arg k "$DEFAULT_KEY" '.recipeResult.connection.target.identityFile = $k' >"$TMP/payload"
STDIN_FILE="$TMP/payload"
run_recipe resume
expect_fails "resume fails when boat resume fails"
expect_has "...and shows boat's own output" "$ERR" "boat resume failed: {\"event\":\"resumed\"}"
expect_eq "...with nothing on stdout" "" "$OUT"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
