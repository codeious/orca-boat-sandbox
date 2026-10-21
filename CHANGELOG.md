# Changelog

## 1.0.0

First public release.

- Runs an Orca workspace in a fresh boat.dev sandbox on macOS and Linux.
- Checks out the repo Orca asks for, then runs the repo's own `setupScript` if one is configured.
- Settings (org, environment, snapshot, machine type, setup script) come from `ORCA_BOAT_*` variables, `~/.config/orca-boat/config.json`, or a `.orca-boat.json` the repo commits.
