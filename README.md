# claude-sandbox

Runs [Claude Code](https://github.com/anthropics/claude-code) in a Docker container, mounting your current directory as the workspace. This gives Claude a sandboxed environment to read and modify files without touching the rest of your system.

Images are tagged `ghcr.io/tartale/claude-sandbox:<tag>` (the repository is configurable with `CS_IMAGE_REPO`). CI does not build or publish them on every change; you build the image you need with [`build-image.sh`](#building-a-custom-image), or the maintainer publishes a release by pushing a `v*` tag.

Your Claude credentials (`~/.claude` and `~/.claude.json`) are bind-mounted into the container so you stay logged in.

The container runs as a user matching your host UID and GID, so files written to the workspace are owned by you. Your shell's umask is also applied inside the container so new files get the expected permissions. Note that on macOS, Docker Desktop runs containers in a Linux VM, so the host umask has no effect — the default umask of the container will be used instead.

## Requirements

- Docker
- An Anthropic account with Claude Code access

## Usage

Set the project up once (see [Setting up a project](#setting-up-a-project)); that creates the scripts below in `.claude/sandbox/`. Then, from anywhere in the project:

```bash
.claude/sandbox/run.sh      # interactive: Claude Code starts in the container in your terminal
.claude/sandbox/start.sh    # background: the container runs detached, Claude waits on its tty
```

Claude Code starts inside a container with the project directory as `/workspace`. The launcher uses the image `ghcr.io/tartale/claude-sandbox:<tag>` (the tag defaults to the project name; override with `CS_IMAGE_TAG` and `CS_IMAGE_REPO`). Docker pulls it if it exists in the registry; otherwise build it first with `.claude/sandbox/build.sh`. Published release images (`:latest`, language tags) reflect the last tagged release, not the latest `main`.

Both scripts name the Claude Code session after the repo (`--name`). `run.sh` names its container `cs-<repo-name>` (`cs-<repo-name>-2`, `-3`… if one is already running) and removes a stopped one of that name first. `start.sh` names its container `cs-<repo-name>`; it prints how to reach it:

```bash
docker attach cs-<repo-name>   # detach again with ctrl-p ctrl-q
docker stop cs-<repo-name>
```

If the container is already running, `start.sh` says so and leaves it. Each start removes a stopped container of that name and creates a new one, so changed variables and flags always apply. Neither script passes `--rm`, so `CS_DOCKER_FLAGS` may include `--restart`; a restarted container keeps the settings it was created with, so `docker stop` it before changing them. Override either name with `CS_CONTAINER_NAME`; `claude-sandbox.sh` on its own appends a random suffix.

### Passing arguments to Claude

Both scripts forward their arguments to `claude`:

```bash
.claude/sandbox/run.sh --continue   # or --resume, or any other claude flag
```

For `start.sh` the arguments apply to the container it starts; a container that is already running is left as it is.

### Using a specific image tag

To use a language-pinned image:

```bash
CS_IMAGE_TAG=go-1.25.10 .claude/sandbox/run.sh
```

### Without a project setup

`claude-sandbox.sh` is what the stubs wrap; it can be run directly from any directory:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/claude-sandbox.sh)"
```

## Setting up a project

Run this from a project's root, on your host (not inside a sandbox), to set the project up for the sandbox:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/init.sh)"
```

It:

- creates `.claude/sandbox/` stubs (a stub you have not edited since `init.sh` last wrote it is updated to the current template; an edited one is asked about only when the template has changed since your last run, so a file you maintain such as `plugin.sh` does not prompt every time; Enter shows the diff first; `m` three-way merges your edits into the new template using the template kept in `.claude/sandbox/.init-base/`, leaving conflict markers where they overlap; a file that is replaced is first copied to `<name>.bak.<timestamp>`, which is git-excluded locally; `.claude/sandbox/.init-hashes` records what was last written and the template seen): `plugin.sh` is where the project's plugins and packages go; `build.sh` builds the project's image from it; `run.sh` starts the sandbox interactively; `start.sh` starts it in the background; `apply-user-patch.sh` applies the patch `claude-user-sync` writes (see [Read-only user scope](#read-only-user-scope)). They wrap the `build-image.sh` and `claude-sandbox.sh` one-liners, and use the repo name as the image tag.
- checks that `envsubst` is installed (needed to read `.env`) and stops with the install command if it is missing, before asking anything; `plugin.sh` lists every built-in plugin, commented out.
- adds the `CS_` launcher settings (`CS_IMAGE_REPO`, `CS_IMAGE_TAG`, `CS_ENV_FILE`, `CS_DOCKER_LOGIN`, and commented-out `CS_USER_CONFIG`, `CS_DOCKER_FLAGS`, `CS_PIDS_LIMIT`, `CS_MEMORY`) with their defaults to `.envrc` in the project root; names already there are left alone.
- opens GitHub's token page with a single-repo fine-grained token pre-filled (Contents, Pull requests and Issues read/write), validates the token you paste (no Administration, can push, no other private repos), and writes `CS_GITHUB_TOKEN` to `.env` at mode 600, excluded from git locally.

All questions (token, registry login, ruleset) are asked up front, before anything is written. The optional ones are:

- store a `write:packages` login for `ghcr.io` in a dedicated docker config (`~/.docker-sandbox`, override with `CS_SANDBOX_DOCKER_CONFIG`), so `CS_DOCKER_LOGIN` shares only that login and not your other registry logins. It prints the launch line and the steps to give the repo access to the package after the first push.
- create a `main` branch ruleset (PR required, no force-push or deletion, no bypass). Needs `gh` logged in as a repo admin. The question is always asked; answering yes without `gh` installed stops the script.

It reads the repo from the `origin` remote (and asks if there is none). `CS_ENV_FILE` picks a different env file for the token.

GitHub cannot create tokens through its API, so the token itself is created in the browser; the script checks it afterwards. It can verify that the token has push access and no Administration permission, but not that Workflows is off, so confirm that on the token page.

## Building a custom image

Put the project's plugins in `.claude/sandbox/plugin.sh`, then run `.claude/sandbox/build.sh`. It builds the project image and pushes it to `CS_IMAGE_REPO:CS_IMAGE_TAG`; `run.sh` and `start.sh` use the same tag. The stub wraps the `build-image.sh` one-liner, which also works on its own, with no repo checkout:

```bash
CS_IMAGE_TAG=my-sandbox /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

Then launch it by setting `CS_IMAGE_TAG` to match:

```bash
CS_IMAGE_TAG=my-sandbox .claude/sandbox/run.sh
```

The examples below call `build-image.sh` directly to show its environment variables.

### Build environment variables

| Variable | Description |
|---|---|
| `CS_IMAGE_REPO` | Image repository to build and push to, e.g. `registry.example.com/team/sandbox` (default: `ghcr.io/tartale/claude-sandbox`) |
| `CS_IMAGE_TAG` | Tag for the built image (default: `custom`) |
| `PLUGINS` | Built-in plugin name, local path, or URL (see [Plugins](#plugins) below) |
| `LANGUAGE_VERSIONS` | Space-separated `<language>-<version>` pins (e.g. `"go-1.25.10"`) |
| `CLAUDE_VERSION` | Claude Code version to bake in (default: latest) |

```bash
# Built-in language plugin
PLUGINS=python3 CS_IMAGE_TAG=my-python /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"

# Built-in plugin with version pin
PLUGINS=go LANGUAGE_VERSIONS="go-1.24.0" CS_IMAGE_TAG=go-1.24 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"

# Local custom plugin script
PLUGINS=./my-tools.sh CS_IMAGE_TAG=my-tools /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"

# Remote custom plugin script
PLUGINS=https://example.com/my-tools.sh CS_IMAGE_TAG=my-tools /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

## Plugins

Plugins are shell scripts that install additional tools into the sandbox. The `plugins/` directory contains ready-made language packs:

| Plugin | Installs | Version format | Example |
|---|---|---|---|
| `plugins/languages/cpp.sh` | `build-essential`, `clang`, `cmake`, `gdb`, `ninja`, `valgrind` | `cpp-<clang-major>` | `cpp-17` |
| `plugins/languages/go.sh` | Go toolchain | `go-<version>` | `go-1.25.10` |
| `plugins/languages/java.sh` | OpenJDK, Maven | `java-<major>` | `java-21` |
| `plugins/languages/python2.sh` | `pip`, `venv`, `pipx`, `uv` | `python-<version>` | `python-3.13.2` |
| `plugins/languages/python3.sh` | `pip`, `venv`, `pipx`, `uv` (uses `python3-` version prefix) | `python3-<version>` | `python3-3.13.2` |
| `plugins/languages/ruby.sh` | Ruby, Bundler | `ruby-<version>` | `ruby-3.3.0` |
| `plugins/languages/rust.sh` | Rust via rustup (`cargo`, `rustc`, `rustfmt`, `clippy`) | `rust-<version>` | `rust-1.78.0` |
| `plugins/languages/typescript.sh` | TypeScript, `ts-node`, `tsx`, `@types/node` | `typescript-<version>` | `typescript-5.4.0` |

All language plugins default to the latest stable version. See [Pinning a language version](#pinning-a-language-version) for details.

The `plugins/tools/` directory contains ready-made tool packs:

| Plugin | Installs |
|---|---|
| `plugins/tools/docker.sh` | Docker CLI (client only), Buildx, and Compose plugins |
| `plugins/tools/playwright.sh` | Playwright CLI/test runner plus Chromium, Firefox, and their system libraries |

Built-in plugins are resolved by name regardless of directory, so `PLUGINS=docker` and `PLUGINS=go` both work. The Docker plugin installs only the client; bind-mount the host's Docker socket so the CLI can reach the host daemon:

```bash
CS_DOCKER_FLAGS="-v /var/run/docker.sock:/var/run/docker.sock" ./claude-sandbox.sh
```

Mounting the socket gives the sandbox root on the host (it can start privileged containers), so the launcher prints a warning when it sees one.

This is an accepted risk, not a safeguarded feature: nothing filters what the agent asks the daemon to do. Mount the socket only in a sandbox whose job needs it (for example an SRE sandbox that rebuilds and restarts the service it owns), never in a general development sandbox, and keep that sandbox's project to one you trust. The launch scripts in `.claude/sandbox` are mounted read-only so the agent cannot add the mount to a launch that did not have it.

The Playwright plugin bakes in the browsers *and* the system libraries they need — the part a plain
`npm install playwright` inside a running sandbox can't do, since installing those libraries needs
root. Browsers land in `/ms-playwright` with `PLAYWRIGHT_BROWSERS_PATH` exported for every shell, so
they resolve whatever uid the container runs as. They are headless natively, so no Xvfb wrapper is
needed. Browser revisions are tied to the Playwright version, so pin it to match the project's own
dependency:

```bash
PLUGINS=playwright LANGUAGE_VERSIONS="playwright-1.55.0" CS_IMAGE_TAG=my-playwright ./build-image.sh
```

### Using a single plugin

Pass a built-in name or path via `PLUGINS`:

```bash
# no repo checkout needed
PLUGINS=go CS_IMAGE_TAG=my-go /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"

# or with a local repo checkout
PLUGINS=plugins/languages/go.sh CS_IMAGE_TAG=my-tag make image
```

### Pinning a language version

Pass `LANGUAGE_VERSIONS` as a space-separated list of `<language>-<version>` entries. Each plugin extracts only its own entry:

```bash
# no repo checkout needed
PLUGINS=go LANGUAGE_VERSIONS="go-1.25.10" CS_IMAGE_TAG=go-1.25.10 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"

# with a local repo checkout
PLUGINS=plugins/languages/go.sh CS_IMAGE_TAG=go-1.25.10 LANGUAGE_VERSIONS="go-1.25.10" make image
```

When a plugin's entry is absent from `LANGUAGE_VERSIONS`, it installs the latest stable version.

Notes:
- **cpp**: version refers to the clang major version installed from the [LLVM apt repo](https://apt.llvm.org)
- **java**: only major versions available in Debian apt are supported (e.g. `11`, `17`, `21`)
- **ruby**: compiles from source via `ruby-build` — expect longer build times

### Using multiple plugins

Point `PLUGINS` at a local directory of `.sh` scripts to run all of them, in alphabetical order:

```bash
# no repo checkout needed
PLUGINS=./my-plugins/ CS_IMAGE_TAG=my-tag /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"

# with a local repo checkout
PLUGINS=plugins/languages CS_IMAGE_TAG=my-tag make image
```

Prefix filenames with numbers to control order when it matters (`01-go.sh`, `02-rust.sh`, …).

### Writing your own plugin

A plugin is any executable shell script. Create one anywhere and point `PLUGINS` at it:

```bash
#!/usr/bin/env bash
set -euo pipefail
apt-get update && apt-get install -y my-tool && rm -rf /var/lib/apt/lists/*
```

The script runs as root during `docker build`, so standard `apt-get` installs work without `sudo`.

### Composing built-in plugins

`PLUGINS_DIR` is pre-populated with the path to the root of the `plugins/` directory. A custom plugin can use it to source built-in language plugins by path.

**Example — a Go + React stack:**

```bash
# go-react.sh
#!/usr/bin/env bash
set -euo pipefail

bash "$PLUGINS_DIR/languages/go.sh"
bash "$PLUGINS_DIR/languages/react.sh"
```

```bash
# no repo checkout needed
PLUGINS=./go-react.sh CS_IMAGE_TAG=go-react /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"

# with a local repo checkout
PLUGINS=plugins/languages/go-react.sh CS_IMAGE_TAG=go-react make image
```

Each sourced plugin respects `LANGUAGE_VERSIONS`, so you can still pin versions:

```bash
PLUGINS=./go-react.sh CS_IMAGE_TAG=go-react \
  LANGUAGE_VERSIONS="go-1.25.10" /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

### Runtime plugins

`PLUGINS` also works at runtime with `claude-sandbox.sh`. The script (or directory) is bind-mounted into the container and executed before Claude starts, letting you run setup steps without rebuilding the image:

```bash
PLUGINS=plugins/languages/python2.sh ./claude-sandbox.sh
```

## Rules and memories

Claude accumulates two very different kinds of knowledge, and they want to live in different places:

- **Project scope** — how *this* codebase is built, tested and deployed; its gotchas and ongoing work. This should travel with the repo, so a teammate (or you on another machine) gets it from a `git pull`.
- **User scope** — who you are and how you like to work. This should follow *you* between projects and between machines, and has no business in any one project's history.

Left alone, the sandbox blurs both. Every project is mounted at `/workspace`, so Claude Code derives the same project key for all of them and piles every project's memories, transcripts and history into a single `~/.claude/projects/-workspace/` bucket on the host. The sandbox splits them instead.

### Project scope

Each project gets its own state bucket on the host, keyed by its real path, and its memory directory is bind-mounted from the project itself:

```
<project>/CLAUDE.md                    project rules            (commit)
<project>/.claude/memory/              project memories         (commit)
<project>/.claude/settings.json        shared project settings  (commit)
<project>/.claude/settings.local.json  machine-local overrides  (gitignore)
```

`.claude/memory/` is the directory Claude writes memories to, so memories recorded during a session land in the project and get committed alongside the code they describe. Add this to the project's `.gitignore`:

```gitignore
.claude/settings.local.json
```

Nothing else under `.claude/` should be ignored — that's the point.

### User scope

User-scope rules and memories live in a small private git repo that you clone on each machine. Point `CS_USER_CONFIG` at the checkout:

```bash
git clone git@github.com:you/claude-user.git ~/.claude-user
export CS_USER_CONFIG="$HOME/.claude-user"
```

The repo is bind-mounted at `/home/claude/.claude-user` and scaffolded on first use:

```
CLAUDE.md          your rules, loaded into every session on every project
memory/MEMORY.md   index of your user-scope memories
memory/*.md        the memories themselves
```

At container start the sandbox pulls the repo, then generates `~/.claude/CLAUDE.md` from it — the scope routing rules, your `CLAUDE.md`, and your memory index, inlined so Claude always has them. That file is regenerated on every start; edit `~/.claude-user/CLAUDE.md` instead.

Because it's a git repo, pushing is what makes a memory reach your other machines. From inside the container:

```bash
claude-user-sync                      # commit everything and push
claude-user-sync "Prefer pnpm"        # with a message
```

Then `git pull` in the checkout on your other machine, or just start a sandbox there — the pull happens automatically.

#### Read-only user scope

A mounted checkout is writable, and the container pushes with the sandbox's GitHub token, so a compromised session could rewrite the rules every future session starts from. To close that off, don't mount the repo. Give the sandbox a second token that can only read it:

```bash
export CS_USER_CONFIG_REPO=you/claude-user
export CS_USER_CONFIG_TOKEN=github_pat_...   # fine-grained, only that repo, Contents: Read-only
```

At start the entrypoint clones the repo into the container, uses the token for that one command, and removes it from the environment before Claude starts. The clone has no remote and vanishes with the container. `claude-user-sync` commits locally and writes `.tmp/claude-user.patch` in the project; review it and apply it from your own checkout with the stub `init.sh` generated:

```bash
.claude/sandbox/apply-user-patch.sh
```

It shows what the patch changes (`v` opens the full diff), asks before applying, then runs `git am` in the checkout named by `CS_USER_CONFIG_CHECKOUT` (default `~/.claude-user`) and pushes. The script is mounted read-only in the sandbox like the other launch scripts, so a session cannot edit it.

Don't grant the project's sandbox token access to the user config repo, or the protection is moot. Set these two variables in your shell, not in `.env`.

### Which scope does something belong in?

Ask whether it would still be true on a different project. "Run the full test suite before pushing" is user scope; "run `./actual test` before pushing" is project scope. Claude is given this rule in the generated `CLAUDE.md`, but it's worth knowing when you're filing things by hand.

### Migrating an existing setup

If you've been running the sandbox already, everything from every project is in `~/.claude/projects/-workspace/` on the host. Nothing is deleted — that bucket is simply no longer used, since each project now mounts its own. To carry old memories forward, sort them by hand:

```bash
ls ~/.claude/projects/-workspace/memory/
# project facts  -> <project>/.claude/memory/   then commit
# personal facts -> ~/.claude-user/memory/      then claude-user-sync
```

Remember to move the matching lines in `MEMORY.md` too, since that index is what Claude reads first.

If you previously hand-symlinked the memory directory into a project, drop the symlink — the bind mount replaces it:

```bash
[ -L ~/.claude/projects/-workspace/memory ] && rm ~/.claude/projects/-workspace/memory
```

## Tests

`make test` runs the bash tests in `tests/` against the launcher with a stubbed `docker` (no daemon needed). The expansion tests need `envsubst` and are skipped without it. CI runs them on every pull request.

## Environment variables

| Variable | Description |
|---|---|
| `CS_IMAGE_REPO` | Image repository, including registry host and namespace (default: `ghcr.io/tartale/claude-sandbox`). Set the same value for `build-image.sh` and the launcher. |
| `CS_IMAGE_TAG` | Tag of the image to use (default: `local`) |
| `CS_DOCKER_FLAGS` | Extra arguments for `docker run`, as one string (e.g. `"-v /var/run/docker.sock:/var/run/docker.sock"`). |
| `CS_CONTAINER_NAME` | Container name (default: `claude-sandbox-<dir>-<random>`; `start.sh` sets `cs-<repo-name>`) |
| `CS_ENV_FILE` | Path to an env file to pass into the container (default: `.env`) |
| `LANGUAGE_VERSIONS` | Space-separated list of language versions in `<language>-<version>` format (e.g. `"go-1.25.10"`). Each plugin extracts its own entry; omitted plugins default to latest stable. |
| `PLUGINS` | Path to a plugin script or directory of plugin scripts to install |
| `CS_USER_CONFIG` | Path to a checkout of your user config repo (user-scope rules and memories). Unset disables the user scope. Read-write; see below for a read-only alternative. |
| `CS_USER_CONFIG_REPO` | `owner/name` of your user config repo, cloned read-only into the container at start. Requires `CS_USER_CONFIG_TOKEN`; mutually exclusive with `CS_USER_CONFIG`. See [Read-only user scope](#read-only-user-scope). |
| `CS_USER_CONFIG_TOKEN` | Fine-grained token with read-only Contents access to that one repo. Removed from the environment before Claude starts. |
| `CS_USER_CONFIG_CHECKOUT` | Your own checkout of the user config repo on the host, where `apply-user-patch.sh` applies the sandbox's patch (default `~/.claude-user`). Not read by the launcher. |
| `CS_DOCKER_LOGIN` | Set to `true` to mount the host's `~/.docker/config.json` (or `$DOCKER_CONFIG/config.json`) read-only so the container's docker CLI can use your registry logins. Off by default; the credentials are readable by anything in the container. Logins held in a credential helper (`credsStore`, e.g. macOS Keychain) are not available in the container. |
| `CS_PIDS_LIMIT` | Maximum number of processes in the container (`docker run --pids-limit`). Unset means no limit. |
| `CS_MEMORY` | Memory limit for the container (`docker run --memory`, e.g. `8g`). Unset means no limit. |

### GitHub token

Set `CS_GITHUB_TOKEN` (e.g. in `.env`) to let `git` and `gh` authenticate inside the container. Whatever the token can do, the agent can do, so use a [fine-grained personal access token](https://github.com/settings/personal-access-tokens) limited to the one repository you are working on, with only *Contents* and *Pull requests* write access, and no administration or workflow permissions.

### Passing environment variables into the container

If a `.env` file exists in the current directory, it is passed to the container via `--env-file`. Use this to inject secrets or project-specific configuration:

```bash
# .env
GITHUB_TOKEN=ghp_...
MY_API_KEY=...
```

The `.env` file follows standard `KEY=VALUE` format. Variables not listed in the file are not passed to the container.

The file is read as data and never run as shell. `$VAR` and `${VAR}` are expanded from your host environment using `envsubst` (macOS: `brew install gettext && brew link --force gettext`; Debian/Ubuntu: `sudo apt-get install gettext-base`), and the result is passed to `docker run --env-file`. Only variables your host exports are expanded, so a literal `$` in a secret is left alone. Command substitution (`$(...)`, backticks) is not run; the launcher warns and passes the text through unchanged. Launcher settings (`CS_*`) belong in your shell environment, not in `.env`.

The env file, `.envrc`, `.git/hooks` and `.claude/sandbox/{build,run,start,apply-user-patch}.sh` are mounted read-only inside the container, because they run on the host later (when you launch, `cd` with direnv, or commit) and an agent must not be able to plant code in them. Edit them from the host. `.claude/sandbox/plugin.sh` stays writable so the agent can maintain the project's dependencies; it only runs inside the image build, but read its `git diff` before running `build.sh`. `.git/config` stays writable, so review `git diff` and `.git/config` before running host-side tooling on a checkout an agent has touched.

To use a different file name, set `CS_ENV_FILE`:

```bash
CS_ENV_FILE=.env.sandbox .claude/sandbox/run.sh
```

## License

MIT
