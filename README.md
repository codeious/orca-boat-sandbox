# Boat.dev sandbox for Orca

An [Orca](https://github.com/stablyai/orca) plugin that runs a workspace in a fresh [Boat.dev](https://boat.dev) sandbox. Orca creates the sandbox when you start the workspace, suspends it when you are done, wakes it when you come back, and deletes it with the workspace.

It works with any Boat.dev account and any GitHub repo. The repo needs no Orca config file, and the plugin has no settings screen.

**Supported:** macOS and Linux desktops. **Not supported: Windows.** Orca runs plugin commands with `cmd.exe` there, and these commands are bash scripts.

## Install

1. Install the Boat.dev CLI (see [boat.dev](https://boat.dev)) and `jq` (`brew install jq` or `apt install jq`).
2. Run `boat login`.
3. In the Boat.dev dashboard, connect your GitHub account. Sandboxes use that login to fetch and push.
4. In Orca, open **Settings → Plugins** and enable plugins.
5. Add the marketplace `https://github.com/codeious/orca-plugins.git`.
6. Install **Boat.dev Sandbox**, read the commands Orca shows, and approve them.
7. When you create a workspace, pick **Run on: Boat.dev sandbox**.

Needs Orca 1.4.199 or later.

To update, refresh the marketplace, choose **Check for update**, and approve the new version.

## What it does

| Orca asks for | The plugin does |
|---|---|
| create | Checks your login and settings first, so a typo fails before anything is billed. Starts a sandbox, pins its SSH host key from boat's own record, checks out the branch and commit Orca asked for, then runs the repo's `setupScript` if it has one. |
| suspend | Stops the sandbox. Billing pauses; boat keeps the disk for 14 days. |
| resume | Starts it again and returns its new address. |
| destroy | Deletes the sandbox and its disk. |

It does not install tools or dependencies. A sandbox has what its image or snapshot has. To install more, give the repo a [setup script](#setup-script).

If create fails, the plugin deletes the sandbox it started. Set `ORCA_BOAT_KEEP_ON_ERROR=1` to keep it for debugging.

## Settings

You do not need any. With none, you get a sandbox from boat's stock image, in your active org, with the default environment and size.

| Setting | Meaning | Default | In a repo file |
|---|---|---|---|
| `org` | Boat organization name or id (`boat org list`) | your active org | yes |
| `environment` | Boat environment (`boat env list`) | your default environment | yes |
| `snapshot` | Named snapshot or `bsh_` share code to start from | boat's stock image | yes |
| `machineType` | `small`, `default`, `large` or `xlarge` | `default` | yes |
| `setupScript` | Path of a script in the repo | none | yes |
| `ghWrapper` | Install the [gh wrapper](#the-gh-wrapper) | `true` | yes |
| `sshUser` | SSH user in the sandbox | `user` | no |
| `identityFile` | SSH key boat set up for you | `~/.ssh/ascii_box_ed25519` | no |

`sshUser` and `identityFile` describe your machine, so a repo file that sets them is refused.

Each setting takes the first value it finds, from top to bottom:

1. An `ORCA_BOAT_*` environment variable: `ORCA_BOAT_ORG`, `ORCA_BOAT_ENVIRONMENT`, `ORCA_BOAT_SNAPSHOT`, `ORCA_BOAT_MACHINE_TYPE`, `ORCA_BOAT_SETUP_SCRIPT`, `ORCA_BOAT_GH_WRAPPER`, `ORCA_BOAT_SSH_USER`, `ORCA_BOAT_IDENTITY_FILE`. Orca must have been started with the variable; a desktop app launched from the dock does not read your shell profile.
2. Your file's entry for the repo, in `~/.config/orca-boat/config.json`.
3. The repo's `.orca-boat.json`.
4. Your file's `defaults`.
5. The built-in default.

```json
{
  "defaults": { "machineType": "large" },
  "repos": {
    "acme/widgets": { "org": "acme", "environment": "widgets-dev" }
  }
}
```

The create log says which layer each value came from. If a named org, environment or snapshot does not exist, create stops before it starts a sandbox, and the error names the layer and how to override it. A repo name in your file matches without regard to letter case.

### Setting up a team

Commit a `.orca-boat.json` to the repo. Editors can check it with `schema/orca-boat.schema.json`.

```json
{
  "$schema": "https://raw.githubusercontent.com/codeious/orca-boat-sandbox/main/schema/orca-boat.schema.json",
  "org": "acme",
  "environment": "widgets-dev",
  "snapshot": "widgets-tools",
  "machineType": "default",
  "setupScript": "scripts/boat-setup.sh"
}
```

Everyone on the team who installs the plugin then gets the same sandbox. `environment` decides which repos boat clones into the sandbox; if it lists the repo, the plugin reuses that clone.

For a private repo in a boat organization, the setup we tested end to end sets both `org` and an `environment` that lists the repo and passes GitHub through, with the org's new sandboxes private. If git cannot reach GitHub from the sandbox, see [Troubleshooting](#troubleshooting).

### Setup script

`setupScript` names a script inside the repo. After the checkout, the plugin runs it on the sandbox with `bash -l` from the project folder. Its output goes to Orca's log. `PROJECT_ROOT`, `REPO_SLUG`, `REPO_BRANCH` and `REPO_HEAD` are set. If it exits non-zero, create fails and the sandbox is deleted.

The script is the one in the commit Orca checks out. The `.orca-boat.json` that names it is read from the folder Orca runs the recipe in.

[`examples/setup-mise-node.sh`](examples/setup-mise-node.sh) installs a repo's tools with mise and its Node dependencies with pnpm or npm. Copy it into your repo and adapt it.

### The gh wrapper

Boat gives each session a short-lived GitHub token in `GITHUB_TOKEN` and keeps a fresh one in `~/.config/gh/hosts.yml`. Orca's long-lived processes on the sandbox keep the first value, so after it expires every `gh` call fails with HTTP 401 and Orca asks you to connect GitHub. The wrapper moves `gh` to `/usr/bin/gh.real` (with `dpkg-divert`) and installs a small script at `/usr/bin/gh` that drops the stale variable when `hosts.yml` has a login. Set `ghWrapper` to `false` to skip it.

## Cost

A sandbox bills from the moment it starts until Orca suspends or deletes it. A stopped sandbox does not bill, and boat keeps its disk for 14 days. A failed create deletes the sandbox it started, so it does not keep billing.

## Security

The commands Orca shows you run on your machine. They call `boat`, `ssh` and `ssh-keygen`, read your boat login state, and add or remove entries for sandbox hosts in `~/.ssh/known_hosts`. Each host key comes from boat's own record, so the first connection is not trust-on-first-use. Nothing is sent anywhere except to boat and to your sandbox.

A repo's `.orca-boat.json` can choose the org, environment, snapshot and setup script, and the repo's code runs in the sandbox anyway. Use the plugin on repos you trust, and name only snapshots you trust. Remotes other than `github.com` are refused, and the plugin never prints a remote URL, because one can hold a token.

## Troubleshooting

- **"boat is not on PATH" or "jq is not on PATH".** Install it. The plugin adds `~/.ascii/bin`, `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` to `PATH`.
- **"you are not logged in to boat".** Run `boat login`.
- **Create waits a long time for GitHub.** A new sandbox can take minutes to get its GitHub login. Create waits up to 240 seconds, and only when the commit Orca pinned is not already on the sandbox. Resume waits 30 seconds and then warns; the checkout is intact, and fetch and push work once boat restores the login.
- **"git cannot reach GitHub from the sandbox", and the create then fails.** A private repo can only be cloned when the sandbox has a GitHub login that git can use. The plugin sets git up with `gh auth setup-git`, but boat has to provide the login. In our tests an org sandbox got your login when it used a boat environment that passes GitHub through (`passGithub`) and the org's new sandboxes were private. Sandboxes in an org whose default visibility was `shared` had none, and boat's help says sharing a sandbox wipes your personal logins from it. Check both: `boat env info <env>` and `boat org default-visibility` (an org admin can set it; it changes the default for every member and only affects new sandboxes). Then put the repo in that environment with `boat env add-repo <env> <owner/name>` and set `environment`. We have not found out which of the two settings matters most. A public repo does not need the login.
- **`orca vm recipe doctor` does not list the recipe.** It cannot see plugin recipes. Create a workspace to test.
- **Read the log.** Every step writes to Orca's recipe log. Set `ORCA_BOAT_KEEP_ON_ERROR=1` before starting Orca to keep a sandbox that failed to create.

## Development

Orca gives a recipe command neither this folder nor any settings, so `recipes/boat-sandbox.json` is generated: `build.mjs` copies the library functions each phase calls from `src/lib.sh` into that phase's script from `src/`, and writes it as one `exec bash -c '...'` command. Orca allows 32 KiB per command; `node build.mjs` prints the sizes. Scripts must run on bash 3.2, the macOS system bash.

```sh
node build.mjs           # regenerate recipes/boat-sandbox.json after editing src/
node build.mjs --check   # recipe is current; bash -n, shellcheck, bash 3.2 lint
bash test/config-test.sh # free tests; boat is a stub
```

`test/run-phase.sh` runs a real create, suspend, resume and destroy cycle on a repo you name. It bills, so it needs `--confirm-paid`; `--dry-run` shows what it would do.

To release: set `version` in `orca-plugin.json` and `CHANGELOG.md`, run `node build.mjs --check`, tag `vX.Y.Z`, and point the marketplace entry's `ref` at the tag.

## License

MIT
