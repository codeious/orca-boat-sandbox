#!/bin/sh
# Installed as /usr/bin/gh on a boat sandbox by the Boat.dev sandbox plugin, with the real binary
# moved to /usr/bin/gh.real. It is not run on the desktop.
#
# boat hands each session a short-lived GitHub token in GITHUB_TOKEN and keeps the same token current
# in ~/.config/gh/hosts.yml. A long-lived process (Orca's relay daemon, and the terminals it starts)
# keeps the value it started with. That token expires, and gh prefers the variable over hosts.yml, so
# every gh call from such a process fails with HTTP 401 and Orca asks to connect GitHub. When
# hosts.yml holds a login, let gh use it.
#
# Orca's relay runs /usr/bin/gh by absolute path, so a wrapper earlier on PATH is never reached.
hosts="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
if [ -n "${GITHUB_TOKEN:-}" ] && grep -q 'oauth_token:' "$hosts" 2>/dev/null; then
  unset GITHUB_TOKEN
fi
exec /usr/bin/gh.real "$@"
