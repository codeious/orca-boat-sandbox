#!/usr/bin/env bash
# Example setupScript: install the repo's tools with mise, then its Node dependencies.
#
# Copy it into your repo (for example scripts/boat-setup.sh), adapt it, and name it in
# .orca-boat.json as "setupScript". The plugin runs it with `bash -l` in the project folder right
# after the checkout; a non-zero exit fails workspace creation.
#
# It expects mise at ~/.local/bin/mise on the sandbox. Put mise in your snapshot, or install it here
# first with: curl -fsSL https://mise.run | sh
set -euo pipefail
export CI=true COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export PATH="$HOME/.local/bin:$PATH"

project_root="${PROJECT_ROOT:-$PWD}"
mise="$HOME/.local/bin/mise"
node_spec=""
has_mise_config=0

step() { printf '\n==> %s\n' "$*" >&2; }
fail() {
  echo "error: $*" >&2
  exit 1
}

# Node comes from mise: the repo's own mise config, else its .node-version / .nvmrc. A repo with
# neither runs on the image's default Node.
setup_toolchain() {
  [ -x "$mise" ] || fail "mise is missing from the sandbox; add it to the snapshot or install it in this script"
  if [ -f mise.toml ] || [ -f .mise.toml ] || [ -f .tool-versions ] || [ -f .config/mise.toml ]; then
    step "mise install"
    # With CI or MISE_YES set, mise trusts configs for that process only and records nothing, so
    # every later login shell would refuse the repo's mise.toml.
    env -u CI -u MISE_YES "$mise" trust --all
    "$mise" install
    has_mise_config=1
  else
    local f want
    for f in .node-version .nvmrc; do
      if [ -f "$f" ]; then
        want="$(tr -d '[:space:]' <"$f")"
        want="${want#v}"
        if [ -n "$want" ]; then
          step "node $want from $f"
          "$mise" install "node@$want"
          node_spec="node@$want"
        fi
        break
      fi
    done
  fi
}

# mise installs the tools, but only `mise activate` (interactive shells) puts them on PATH, so a login
# shell, an ssh command or an agent shell would run the image's own tools. Its shims directory fixes
# that for every shell. It goes at the end of .profile (after that file's own PATH edits) and above the
# interactive-shell guard in .bashrc, which non-interactive ssh commands also read.
expose_mise_tools() {
  local shims="$HOME/.local/share/mise/shims" begin="# boat-setup: mise shims START" end="# boat-setup: mise shims END"
  # shellcheck disable=SC2016 # the line is written to a profile file and expands there
  local line='export PATH="$HOME/.local/share/mise/shims:$PATH"' f tmp
  "$mise" reshim
  [ -d "$shims" ] || fail "mise created no shims directory at $shims"
  for f in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$f"
    tmp="$(mktemp)"
    awk -v b="$begin" -v e="$end" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$f" >"$tmp"
    {
      if [ "${f##*/}" = ".bashrc" ]; then printf '%s\n%s\n%s\n' "$begin" "$line" "$end"; fi
      cat "$tmp"
      if [ "${f##*/}" = ".profile" ]; then printf '%s\n%s\n%s\n' "$begin" "$line" "$end"; fi
    } >"$f"
    rm -f "$tmp"
  done
}

# Every binary the repo's tools provide must resolve to its shim in a plain login shell.
verify_plain_shell_tools() {
  local names missed dir
  names="$(for dir in $("$mise" bin-paths 2>/dev/null); do ls "$dir"; done | sort -u | tr '\n' ' ')"
  [ -n "$names" ] || return 0
  # $names is meant to split into one argument per tool, and the quoted script expands in the child shell.
  # shellcheck disable=SC2086,SC2016
  missed="$(env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin bash -lc '
    cd "$1" || exit 1
    shift
    for n in "$@"; do
      case "$(command -v "$n" 2>/dev/null)" in "$HOME"/.local/share/mise/shims/*) ;; *) echo "$n" ;; esac
    done' _ "$project_root" $names 2>/dev/null | head -n 5 | tr '\n' ' ')"
  [ -z "$missed" ] || fail "a plain login shell does not resolve these tools to mise: $missed"
}

run_tool() {
  if [ -n "$node_spec" ]; then "$mise" exec "$node_spec" -- "$@"; else "$mise" exec -- "$@"; fi
}

# A plain login shell, like the one Orca opens, must resolve the toolchain too. Node is only required
# of repos that use it, so a Java or Python repo is not held to it.
verify_toolchain() {
  local have
  if [ -f package.json ] || [ -n "$node_spec" ]; then
    have="$(env -u CI -u MISE_YES "$mise" exec ${node_spec:+"$node_spec"} -- node --version 2>&1)" ||
      fail "a plain shell cannot run node in $project_root: $(printf '%s' "$have" | head -n 3 | tr '\n' ' ')"
    echo "node $have" >&2
  else
    have="$(env -u CI -u MISE_YES "$mise" exec -- true 2>&1)" ||
      fail "a plain shell cannot load the mise toolchain in $project_root: $(printf '%s' "$have" | head -n 3 | tr '\n' ' ')"
    echo "tools: $(env -u CI -u MISE_YES "$mise" current 2>/dev/null | tr '\n' ' ')" >&2
  fi
  if [ "$has_mise_config" = 1 ]; then verify_plain_shell_tools; fi
}

install_dependencies() {
  [ -f package.json ] || {
    echo "no package.json; skipping dependency install" >&2
    return 0
  }
  if [ -n "$(run_tool node -p "require('./package.json').packageManager || ''")" ]; then
    run_tool corepack enable
    run_tool corepack install
  fi
  if [ -f pnpm-lock.yaml ]; then
    step "pnpm install --frozen-lockfile"
    run_tool pnpm install --frozen-lockfile
  elif [ -f package-lock.json ]; then
    step "npm ci"
    run_tool npm ci
  else
    echo "warning: no pnpm-lock.yaml or package-lock.json; skipped the dependency install" >&2
  fi
}

cd "$project_root"
setup_toolchain
if [ "$has_mise_config" = 1 ]; then expose_mise_tools; fi
verify_toolchain
install_dependencies
