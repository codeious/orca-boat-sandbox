# Boat.dev sandbox for Orca

An [Orca](https://github.com/stablyai/orca) plugin that runs each workspace in its own [Boat.dev](https://boat.dev) sandbox. Orca creates the sandbox when you start the workspace, suspends it when you are done, wakes it when you come back, and deletes it with the workspace.

It works with any Boat.dev account and any GitHub repo. With no settings, you get boat's stock Ubuntu image. A team can share a boat organization, an environment with logins and secrets, and a tools snapshot, so everyone's workspaces start the same way.

**Supported:** macOS and Linux desktops, and repos on github.com.

**Not supported:**
- **Windows.** Orca runs plugin commands with `cmd.exe` there, and these commands are bash scripts.
- **Other Git hosts.** A sandbox only has a GitHub login.

[Install](#install) · [What it does](#what-it-does) · [Settings](#settings) · [Using it with a team](#using-it-with-a-team) · [Agents in the sandbox](#agents-in-the-sandbox) · [Building a tools snapshot](#building-a-tools-snapshot) · [Cost](#cost) · [Security](#security) · [Troubleshooting](#troubleshooting) · [Development](#development)

## Install

You need Orca 1.4.199 or later, the [Boat.dev CLI](https://boat.dev), and `jq` (`brew install jq` or `apt install jq`).

1. Sign in to boat with `boat onboard` (or `boat login`).
2. In the Boat.dev dashboard, connect your GitHub account. Sandboxes use that login to clone, fetch and push.
3. In Orca, open **Settings → Plugins** and turn plugins on.
4. Add the marketplace `https://github.com/codeious/orca-plugins.git`.
5. Install **Boat.dev Sandbox**, read the commands Orca shows, and approve them.
6. When you create a workspace, pick **Run on: Boat.dev sandbox**.

**Updating:** Orca keeps its own copy of the marketplace and does not see a new release until you refresh it.
1. In **Settings → Plugins**, click **Refresh** in the marketplace.
2. Click **Check for update** on Boat.dev Sandbox.
3. Approve the new version.

## What it does

| Orca asks for | The plugin does |
|---|---|
| create | Checks your login and settings first, so a typo fails before anything is billed. Then it starts a sandbox and pins its SSH host key from boat's own record. It checks out the branch and commit Orca asked for at `/home/user/<repo name>`, and runs the repo's `setupScript` if it has one. |
| suspend | Stops the sandbox. Billing pauses; boat keeps the disk for 14 days. |
| resume | Starts it again and returns its new address. |
| destroy | Deletes the sandbox and its disk. |

It does not install tools or dependencies. A sandbox has what its image or snapshot has. To add more, build a [tools snapshot](#building-a-tools-snapshot) or give the repo a [setup script](#setup-script).

If create fails, the plugin deletes the sandbox it started. Set `ORCA_BOAT_KEEP_ON_ERROR=1` to keep it for debugging.

## Settings

You do not need any. With none, you get a sandbox from boat's stock image, in your active org, with your default environment and size.

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
2. Your file's entry for the repo, in `~/.config/orca-boat/config.json` (or under `$XDG_CONFIG_HOME`).
3. The repo's `.orca-boat.json`.
4. Your file's `defaults`.
5. The built-in default.

```json
{
  "defaults": { "org": "acme", "environment": "acme-dev" },
  "repos": {
    "acme/widgets": { "machineType": "large" }
  }
}
```

Your `defaults` apply only where the repo file sets nothing; a `repos` entry wins over the repo file. A repo name matches without regard to letter case. The create log says which layer each value came from. If a named org, environment or snapshot does not exist, create stops before it starts a sandbox, and the error names the layer and how to override it.

### Setup script

`setupScript` names a script inside the repo. After the checkout, the plugin runs it on the sandbox with `bash -l` from the project folder. Its output goes to Orca's log. `PROJECT_ROOT`, `REPO_SLUG`, `REPO_BRANCH` and `REPO_HEAD` are set. If it exits non-zero, create fails and the sandbox is deleted.

The script is the one in the commit Orca checks out. The `.orca-boat.json` that names it is read from the folder Orca runs the recipe in.

[`examples/setup-mise-node.sh`](examples/setup-mise-node.sh) installs a repo's tools with mise and its Node dependencies with pnpm or npm. Copy it into your repo and adapt it.

### The gh wrapper

Boat gives each session a short-lived GitHub token in `GITHUB_TOKEN` and keeps a fresh one in `~/.config/gh/hosts.yml`. Orca's long-lived processes on the sandbox keep the first value. After it expires, every `gh` call fails with HTTP 401 and Orca asks you to connect GitHub.

The wrapper fixes this. It moves `gh` to `/usr/bin/gh.real` (with `dpkg-divert`) and installs a small script at `/usr/bin/gh`. When `hosts.yml` has a login, the script drops the stale variable. Set `ghWrapper` to `false` to skip it.

## Using it with a team

The plugin has no team settings of its own. A team shares these in Boat.dev, and each repo names them in a committed `.orca-boat.json`:

| Shared in Boat.dev | Why |
|---|---|
| An organization | Sandboxes bill to it, and its members can use its environments and snapshots. |
| An environment for workspaces | It gives every sandbox the creator's GitHub and agent logins, plus shared variables and files. |
| A tools snapshot (optional) | Every sandbox starts with the same tools. See [Building a tools snapshot](#building-a-tools-snapshot). |

### Admin: set it up once

1. **Create the organization.** Use the dashboard or `boat org create`. Invite people with `boat --org <org> org invite <email>`. Each member may need a seat on the org's plan.
2. **Make new sandboxes private.** Run `boat --org <org> org default-visibility private`. Boat wipes the creator's personal logins off a shared sandbox, and then it cannot clone a private repo.
3. **Create the environment for workspaces** and let it pass logins through:

   ```sh
   boat --org <org> env new <env>
   boat --org <org> env set <env> --github true --agents-credentials true --secrets true \
     --boat-credentials false --safe-for-third-parties false
   ```

   It does not need to list your repos, because the plugin clones the repo itself. If it does list one, boat clones that repo when the sandbox starts and the plugin reuses that copy.
4. **Add shared values.** Given only a name, `boat env set-var` reads the value from stdin, which keeps it out of your shell history. Secret files are written relative to `/home/user`:

   ```sh
   boat --org <org> env set-var <env> SOME_API_KEY
   boat --org <org> env set-file <env> .config/some-tool/config.json --from ./config.json
   ```

   Each change makes a new environment version. New sandboxes get it at once; running ones need `boat --org <org> env upgrade <env>`.
5. **Optionally,** [build a tools snapshot](#building-a-tools-snapshot).
6. **Commit a `.orca-boat.json` to each repo.** Editors can check it against [`schema/orca-boat.schema.json`](schema/orca-boat.schema.json):

   ```json
   {
     "$schema": "https://raw.githubusercontent.com/codeious/orca-boat-sandbox/main/schema/orca-boat.schema.json",
     "org": "acme",
     "environment": "acme-dev",
     "snapshot": "acme-tools"
   }
   ```

   For repos that have no file yet, members can put the same three values in the `defaults` of their own `config.json`.

### Member: join

1. **Join the org.** Accept the invite, then check that `boat org list` shows the organization.
2. **Install.** Follow [Install](#install). Connect your own GitHub account in the dashboard, because each sandbox gets the login of whoever creates it.
3. **Create a workspace** on a repo that has a `.orca-boat.json`. The create log names the org, environment and snapshot it used.

## Agents in the sandbox

Boat's stock image has Claude Code and Codex. With `--agents-credentials true`, boat signs them in with the logins you saved under **Agents & Proxying** in the boat dashboard.

For any other agent, store its config in the environment as a secret file, and store its key as a variable. Droid, for example, reads `~/.factory/settings.json`, and a custom model there can read its key from the environment with `"apiKey": "${MY_PROXY_KEY}"`:

```sh
boat --org <org> env set-file <env> .factory/settings.json --from ./sandbox-droid-settings.json
boat --org <org> env set-var <env> MY_PROXY_KEY
```

What matters for Droid in a sandbox:

- **Keep the file valid JSON.** Orca adds its own status hooks to `~/.factory/settings.json` when it connects. Do not set `hooksDisabled`, or Orca cannot show the agent's state.
- **Pre-trust the folders.** Droid asks "Trust this folder?" once per folder. The repo is at `/home/user/<repo name>`, so list those folders under `trustedFolders`. Also list `/var/lib/ascii-lazy/retired/home`. When boat finishes restoring a sandbox's files, a process that was already inside `/home/user` sees its folder under that path, and Droid asks again.
- **Remember the key is readable.** Anyone who runs code in the sandbox can read the key variable.

## Building a tools snapshot

A named snapshot is a saved sandbox disk. Building one is a manual, paid step: start a sandbox, install tools, stop it, save it, and delete it.

```sh
boat --org <org> env new <build-env>
boat --org <org> env set <build-env> --github false --agents-credentials false --secrets false \
  --boat-credentials false --safe-for-third-parties false
boat --org <org> new --environment <build-env> --type small --name tools-build
boat --org <org> ssh <id>               # install your tools, then exit
boat --org <org> stop <id>
boat --org <org> snapshot <id> <name>
boat --org <org> delete <id> --yes
```

Rules we learned by testing:

- **Never build from `boat new --no-env`.** Boat then withholds logins from every sandbox created from that snapshot, even when its environment passes GitHub through. Build from an environment with every toggle off, as above. `boat info <id> --json` should show `"holdsCreatorLogins": false` for the build sandbox and `true` for your workspaces.
- **Put tools in `/usr/local/bin`.** `boat ssh` and `boat exec` start shells that do not read `~/.profile`, so a tool only in `~/.local/bin` is "command not found" there. Install it there or link it: `sudo ln -s ~/.local/bin/<tool> /usr/local/bin/<tool>`.
- **Keep credentials and repos out.** Do not sign in to anything during the build. The environment adds logins per workspace.

Saving under an existing name replaces the snapshot. Workspaces that already exist keep their disk.

## Cost

A sandbox bills from the moment it starts until Orca suspends or deletes it. A stopped sandbox does not bill, and boat keeps its disk for 14 days. A failed create deletes the sandbox it started, so it does not keep billing. `small` runs at half the `default` rate, and `large` at twice. `boat usage <id>` shows what one sandbox has cost.

## Security

The commands Orca shows you run on your machine. They call `boat`, `ssh` and `ssh-keygen`, read your boat login state, and add or remove entries for sandbox hosts in `~/.ssh/known_hosts`. Each host key comes from boat's own record, so the first connection is not trust-on-first-use. Nothing is sent anywhere except to boat and to your sandbox.

A repo's `.orca-boat.json` can choose the org, environment, snapshot and setup script, and the repo's code runs in the sandbox anyway. Use the plugin on repos you trust, and name only snapshots you trust. The plugin never prints a remote URL, because one can hold a token.

Anyone who can run code in a sandbox can read the variables, files and logins boat put there. Rotate a shared key when someone leaves the team.

## Troubleshooting

- **"boat is not on PATH" or "jq is not on PATH".** Install it. The plugin adds `~/.ascii/bin`, `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` to `PATH`.
- **"you are not logged in to boat".** Run `boat login`.
- **"git cannot reach GitHub from the sandbox", and create fails.** Check these in order:
  1. **Plugin version.** It must be 1.0.1 or later. 1.0.0 printed "no GitHub login on the sandbox" and "connect GitHub in the boat dashboard", and it failed even when the login was there. [Update it](#install).
  2. **GitHub connection.** Your GitHub account must be connected in the boat dashboard.
  3. **Environment.** It must pass GitHub through: `boat --org <org> env info <env> --json | jq .environment.passGithub` should print `true`.
  4. **Visibility.** `boat --org <org> org default-visibility` must say `private`.
  5. **Snapshot.** It must not have been built from a `--no-env` sandbox. In a sandbox kept with `ORCA_BOAT_KEEP_ON_ERROR=1`, `boat info <id> --json` shows `"holdsCreatorLogins": true` when boat injected your logins.

  A public repo needs none of this.
- **Resume warns that git cannot reach GitHub.** Resume waits 30 seconds and then carries on. The checkout is intact, and fetch and push work once boat restores the login.
- **A tool is "command not found" in the sandbox.** It is probably in `~/.local/bin` only. See [Building a tools snapshot](#building-a-tools-snapshot).
- **`orca vm recipe doctor` does not list the recipe.** It cannot see plugin recipes. Create a workspace to test.
- **Read the log.** Every step writes to Orca's recipe log. Set `ORCA_BOAT_KEEP_ON_ERROR=1` before starting Orca to keep a sandbox that failed to create.

## Development

Orca gives a recipe command neither this folder nor any settings, so `recipes/boat-sandbox.json` is generated. `build.mjs` copies the library functions each phase calls from `src/lib.sh` into that phase's script from `src/`, and writes it as one `exec bash -c '...'` command. Orca allows 32 KiB per command; `node build.mjs` prints the sizes. Scripts must run on bash 3.2, the macOS system bash.

```sh
node build.mjs           # regenerate recipes/boat-sandbox.json after editing src/
node build.mjs --check   # recipe is current; bash -n, shellcheck, bash 3.2 lint
bash test/config-test.sh # free tests; boat is a stub
```

`test/run-phase.sh` runs a real create, suspend, resume and destroy cycle on a repo you name. It bills, so it needs `--confirm-paid`; `--dry-run` shows what it would do.

To release:
1. Set `version` in `orca-plugin.json` and `CHANGELOG.md`.
2. Run `node build.mjs --check`.
3. Tag `vX.Y.Z`.
4. Point the marketplace entry's `ref` at the tag.

## License

MIT
