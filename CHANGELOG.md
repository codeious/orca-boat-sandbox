# Changelog

## 1.0.1

- Fixes the GitHub access check on a new sandbox. The sandbox has a `gh` login but no git credential helper until `gh auth setup-git` runs, so the check failed and create waited up to 240 seconds, then could fail on a private repo that boat had not cloned. The check and the checkout now run `gh auth setup-git` first.
- Clearer errors when git cannot reach GitHub from the sandbox; the README troubleshooting entry matches what we tested.

## 1.0.0

First public release.

- Runs an Orca workspace in a fresh boat.dev sandbox on macOS and Linux.
- Checks out the repo Orca asks for, then runs the repo's own `setupScript` if one is configured.
- Settings (org, environment, snapshot, machine type, setup script) come from `ORCA_BOAT_*` variables, `~/.config/orca-boat/config.json`, or a `.orca-boat.json` the repo commits.
