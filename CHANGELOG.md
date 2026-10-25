# Changelog

## 1.0.3

- Keeps Orca connected when boat gives a restarted sandbox a new machine ID. Orca 1.4.240 and later tie their server on the sandbox to `/etc/machine-id`; after a change, Orca started a second server it could not sign in to and reported `orcad_identity_mismatch`. Create and resume now list the machine IDs they see on the sandbox, and resume puts back the one Orca's server belongs to before Orca connects. It also stops the second server if Orca already started one. Resume only warns if it cannot. Workspaces created by 1.0.2 or earlier do not get this.
- Adds `bin/orca-boat-wake`. It marks a boat workspace in Orca for a wake when boat restarted the sandbox while Orca showed it as running, so the next click runs resume and picks up the new address. See Troubleshooting in the README.
- The generated commands leave out the library's doc comments, which frees about 4 KB in create.

## 1.0.2

- Gives git in the sandbox your name and email, so commits work without any setup. Create reads `user.name` and `user.email` from your git config for the repo and sets them in the sandbox's global git config, unless the sandbox already has them. Resume puts them back if the sandbox lost them. Workspaces created by 1.0.1 or earlier still need them set by hand, or a new workspace.

## 1.0.1

- Fixes the GitHub access check on a new sandbox. The sandbox has a `gh` login but no git credential helper until `gh auth setup-git` runs, so the check failed and create waited up to 240 seconds, then could fail on a private repo that boat had not cloned. The check and the checkout now run `gh auth setup-git` first.
- Clearer errors when git cannot reach GitHub from the sandbox; the README troubleshooting entry matches what we tested.

## 1.0.0

First public release.

- Runs an Orca workspace in a fresh boat.dev sandbox on macOS and Linux.
- Checks out the repo Orca asks for, then runs the repo's own `setupScript` if one is configured.
- Settings (org, environment, snapshot, machine type, setup script) come from `ORCA_BOAT_*` variables, `~/.config/orca-boat/config.json`, or a `.orca-boat.json` the repo commits.
