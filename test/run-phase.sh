#!/usr/bin/env bash
# PAID: creates a real boat.dev sandbox, which bills until it is suspended or deleted.
#
# Runs the generated recipe commands the way Orca does: `sh -c "<command>"` from the repo folder,
# with a minimal PATH, the ORCA_* variables, and the lifecycle JSON on stdin. One full cycle:
# create, check the checkout over SSH, suspend, resume, check again, destroy.
#
#   bash test/run-phase.sh --confirm-paid [options] <owner/name>
#
#   --repo-path DIR      run from DIR, so its .orca-boat.json applies (default: an empty folder,
#                        which means stock settings)
#   --remote-check CMD   also run CMD in the project folder on the sandbox, with `bash -l`
#   --simulate-machine-id-change
#                        after create, write an Orca server claim for the machine ID and then change
#                        the ID, as boat does on a restart; resume must put the original back
#   --keep               do not destroy the sandbox at the end; prints how to delete it
#   --dry-run            print what would run and exit; costs nothing
#
# The sandbox is destroyed on exit, also after a failure, unless --keep is given.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECIPE="$ROOT/recipes/boat-sandbox.json"

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}
log() { printf '\n[run-phase] %s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

confirmed=0 dry_run=0 keep=0 slug="" repo_path="" remote_check="" simulate_mid=0
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm-paid) confirmed=1 ;;
    --dry-run) dry_run=1 ;;
    --keep) keep=1 ;;
    --simulate-machine-id-change) simulate_mid=1 ;;
    --repo-path)
      repo_path="${2:?--repo-path needs a folder}"
      shift
      ;;
    --remote-check)
      remote_check="${2:?--remote-check needs a command}"
      shift
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) slug="$1" ;;
  esac
  shift
done
[[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage
if [ "$confirmed" != 1 ] && [ "$dry_run" != 1 ]; then
  echo "This creates a real, billed boat.dev sandbox. Run again with --confirm-paid (or --dry-run)." >&2
  exit 2
fi
for tool in jq git ssh node; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"; done
node "$ROOT/build.mjs" --check >/dev/null || die "the recipe is not up to date or fails its checks; run: node build.mjs --check"

work="$(mktemp -d "${TMPDIR:-/tmp}/boat-run-phase.XXXXXX")"
result="$work/result.json"
if [ -z "$repo_path" ]; then
  repo_path="$work/repo"
  mkdir -p "$repo_path"
fi
repo_path="$(cd "$repo_path" && pwd)"

# The default branch and its tip, the way Orca would pin them.
remote_url="https://github.com/$slug.git"
symref="$(git ls-remote --symref "$remote_url" HEAD)" || die "cannot read $remote_url"
base_ref="$(printf '%s\n' "$symref" | awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2; exit }')"
head_sha="$(printf '%s\n' "$symref" | awk '$1 != "ref:" && $2 == "HEAD" { print $1; exit }')"
if [ -z "$base_ref" ] || [ -z "$head_sha" ]; then die "could not resolve the default branch of $slug"; fi
branch="orca-boat-test-$(date +%s)"
instance="run-phase-$$"
log "repo $slug, base $base_ref at ${head_sha:0:12}, branch $branch, run folder $repo_path"
if [ -f "$repo_path/.orca-boat.json" ]; then log "using $repo_path/.orca-boat.json"; else log "no .orca-boat.json: stock settings"; fi

command_for() { jq -er --arg p "$1" '.[$p]' "$RECIPE"; }

# stdin file -> stdout and stderr of the recipe command.
run_phase() { # phase stdin_file
  local command
  command="$(command_for "$1")"
  (
    cd "$repo_path"
    env PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      ORCA_VM_MODE="$1" ORCA_VM_INSTANCE_ID="$instance" ORCA_RECIPE_ID=boat-sandbox \
      ORCA_PROJECT_ID=run-phase-project ORCA_WORKSPACE_ID=run-phase-workspace ORCA_WORKSPACE_NAME="$branch" \
      ORCA_REPO_PATH="$repo_path" ORCA_REPO_URL="git@github.com:$slug.git" ORCA_REPO_BRANCH="$branch" \
      ORCA_REPO_REF="$base_ref" ORCA_REPO_REF_HEAD="$head_sha" \
      ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 ORCA_VERSION=run-phase \
      sh -c "$command" <"$2"
  )
}

write_lifecycle() { # mode -> file
  jq -cn --arg mode "$1" --arg id "$instance" --arg name "$branch" --slurpfile r "$result" '{
    schemaVersion: 1, mode: $mode, recipeId: "boat-sandbox", instanceId: $id,
    projectId: "run-phase-project", workspaceId: "run-phase-workspace", workspaceName: $name,
    recipeResult: $r[0]
  }' >"$work/lifecycle-$1.json"
  printf '%s' "$work/lifecycle-$1.json"
}

if [ "$dry_run" = 1 ]; then
  for phase in create suspend resume destroy; do
    log "dry run: $phase is $(command_for "$phase" | wc -c | tr -d ' ') bytes; first line: $(command_for "$phase" | head -n 1)"
  done
  log "dry run: nothing was started"
  rm -rf "$work"
  exit 0
fi

sandbox_id=""
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -s "$result" ] && [ "$keep" != 1 ]; then
    log "destroying the sandbox"
    run_phase destroy "$(write_lifecycle destroy)" || log "DESTROY FAILED: delete the sandbox yourself: boat delete $sandbox_id --yes"
  elif [ -n "$sandbox_id" ]; then
    org="$(jq -r '.userData.org // empty' "$result")"
    log "kept sandbox $sandbox_id (billing). Delete it with: boat${org:+ --org $org} delete $sandbox_id --yes"
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

# Reads the result of create or resume into $result after checking its shape.
take_result() { # file
  jq -e '.schemaVersion == 2 and .checkoutMode == "provisioned-root" and .connection.type == "ssh"
    and (.connection.target | (.host and .port and .username and .identityFile and .identitiesOnly == true))
    and .userData.provider == "boat"' "$1" >/dev/null || die "the recipe printed a result Orca would reject: $(cat "$1")"
  cp "$1" "$result"
  sandbox_id="$(jq -r '.userData.resourceId' "$result")"
}

# Connects the way Orca will: the pinned key, strict host-key checking, the identity from the result.
check_checkout() {
  local host port user key root out
  host="$(jq -r '.connection.target.host' "$result")"
  port="$(jq -r '.connection.target.port' "$result")"
  user="$(jq -r '.connection.target.username' "$result")"
  key="$(jq -r '.connection.target.identityFile' "$result")"
  root="$(jq -r '.connection.projectRoot' "$result")"
  out="$(ssh -p "$port" -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=20 "$user@$host" "git -C '$root' rev-parse HEAD; git -C '$root' rev-parse --abbrev-ref HEAD")" ||
    die "cannot SSH to $user@$host:$port with strict host-key checking"
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "$head_sha" ] || die "the sandbox is not at $head_sha: $out"
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "$branch" ] || die "the sandbox is not on branch $branch: $out"
  log "checkout is at ${head_sha:0:12} on $branch"
  if [ -n "$remote_check" ]; then
    log "remote check: $remote_check"
    ssh -p "$port" -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=20 "$user@$host" "cd '$root' && bash -l -c $(printf '%q' "$remote_check")" ||
      die "the remote check failed"
  fi
}

# Runs a command on the sandbox the way Orca connects: the pinned key, the identity from the result.
sandbox_ssh() { # remote command...
  ssh -p "$(jq -r '.connection.target.port' "$result")" -i "$(jq -r '.connection.target.identityFile' "$result")" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20 \
    "$(jq -r '.connection.target.username' "$result")@$(jq -r '.connection.target.host' "$result")" "$@"
}

# Stands in for Orca and boat after create: Orca's claim for the machine ID create recorded, the way
# Orca writes ~/.orca-remote/orcad-machine.json, then a new machine ID, as boat gives a restarted sandbox.
# The heredoc lives in a function because bash 3.2 cannot parse one inside $( ).
machine_id_change_script() {
  cat <<'REMOTE'
set -euo pipefail
orig="$(cat /etc/machine-id)"
grep -qxF "$orig" "$HOME/.local/state/orca-boat/machine-ids" || { echo "create did not record the machine ID" >&2; exit 3; }
mkdir -p "$HOME/.orca-remote"
printf '{"schemaVersion":1,"machineKey":"%s"}' "$(printf 'linux:%s' "$orig" | sha256sum | cut -c1-16)" \
  >"$HOME/.orca-remote/orcad-machine.json"
new="$(tr -d '-' </proc/sys/kernel/random/uuid)"
printf '%s\n' "$new" | sudo -n tee /etc/machine-id >/dev/null
printf '%s %s\n' "$orig" "$new"
REMOTE
}

simulate_machine_id_change() {
  local out
  out="$(machine_id_change_script | sandbox_ssh 'bash -s')" || die "could not simulate a machine-ID change"
  machine_id_orig="${out%% *}"
  machine_id_fake="${out##* }"
  log "machine ID ${machine_id_orig:0:8}... recorded by create; replaced it with ${machine_id_fake:0:8}..."
}

check_machine_id() {
  local out now seen
  out="$(sandbox_ssh 'cat /etc/machine-id; tail -n 2 ~/.local/state/orca-boat/machine-ids | head -n 1')" ||
    die "could not read the machine ID"
  now="$(printf '%s\n' "$out" | sed -n 1p)"
  seen="$(printf '%s\n' "$out" | sed -n 2p)"
  [ "$now" = "$machine_id_orig" ] || die "resume did not put back the machine ID (it is ${now:0:8}...)"
  if [ "$seen" = "$machine_id_fake" ]; then
    log "resume put back the machine ID; boat kept the one set before suspend"
  else
    log "resume put back the machine ID; boat had given the sandbox a new one (${seen:0:8}...) on start"
  fi
}

timed() { # label command...
  local label="$1" started=$SECONDS
  shift
  log "== $label"
  "$@"
  log "$label took $((SECONDS - started))s"
}

phase_create() {
  run_phase create /dev/null >"$work/create.json"
  take_result "$work/create.json"
  log "sandbox $sandbox_id"
}
phase_suspend() { run_phase suspend "$(write_lifecycle suspend)"; }
phase_resume() {
  run_phase resume "$(write_lifecycle resume)" >"$work/resume.json"
  take_result "$work/resume.json"
}

timed create phase_create
check_checkout
if [ "$simulate_mid" = 1 ]; then simulate_machine_id_change; fi
timed suspend phase_suspend
timed resume phase_resume
check_checkout
if [ "$simulate_mid" = 1 ]; then check_machine_id; fi
log "full cycle passed"
