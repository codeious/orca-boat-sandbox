# Changelog

## 1.2.0

- Adds a recipe per sandbox size, so you pick the size when you create a workspace: under **Run on**, choose **Boat.dev sandbox (small)**, **(default size)**, **(large)** or **(xlarge)**. A size recipe beats `machineType` from every layer. **Boat.dev sandbox** still takes the size from your settings, and workspaces created before 1.2.0 keep working.
## 1.1.1

- Docs only. The README says `orca-boat watch` and `orca-boat link` need macOS, and Security covers what `orca-boat` changes on your machine and the sandbox.
## 1.1.0

- `recovery` is `snapshot` by default. Create stores it with the workspace, `off` included, so a later change of the default does not change an existing workspace. A workspace with nothing stored (created by 1.0.4 or earlier without the setting) uses `ORCA_BOAT_RECOVERY`, else `defaults.recovery` in your config file, else `off`.
- Resume tries more before it gives up on a sandbox boat cannot resume: `boat recover` (skipped on bare metal, where boat refuses it), then a normal stop and resume, which keeps the disk. With `recovery: snapshot` it then tries a forced stop and resume, and only then a fork of the latest snapshot. Resume also moves stale Orca server locks on the sandbox to `~/.orca-recovery`, so Orca's server can start after a restart.
- Adds `bin/orca-boat`. `doctor` checks every boat workspace layer by layer and changes nothing; `fix` repairs one with the same steps as resume (`--safe` never force-stops or forks), then moves stale locks and marks the workspace for a wake, or points it at a fork. `watch install` adds a launchd job that fixes a workspace found broken on two runs in a row. `link` runs Orca's server on a sandbox paired as an Orca runtime as a systemd user service, forwards it with a launchd `boat forward` by sandbox id, and pairs it. See Recovering an unrecoverable sandbox in the README.

## 1.0.4

- Adds the `recovery` setting for a sandbox that is stuck `stopping` and that `boat resume` refuses. Off by default. With `recovery: snapshot`, resume first power-cycles the sandbox with `boat recover`, which leaves its disk alone. If that does not help, it forks the sandbox's latest snapshot with `boat fork` into a new sandbox with the same org, environment and size, and returns the fork so Orca moves the workspace to it. Disk changes made after that snapshot are not on the fork. The stuck sandbox is kept, and resume logs the command to delete it. The setting is stored with the workspace at create time, so workspaces created by 1.0.3 or earlier have recovery off.
- Adds `bin/orca-boat-recover`, for a stuck sandbox when Orca still shows the workspace as running, so resume never runs, or when `recovery` was off. It forks the latest snapshot, stops the fork, and points the workspace at it in Orca's runtime file (backed up first). Click the workspace afterwards and resume does the rest. See Recovering an unrecoverable sandbox in the README.

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
