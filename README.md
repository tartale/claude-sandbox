# claude-sandbox

Runs [Claude Code](https://github.com/anthropics/claude-code) in a Docker container with your project mounted at `/workspace`, so Claude can read and modify files without touching the rest of your system. The container runs as your UID and GID, so files it writes are yours.

## Requirements

- Docker
- An Anthropic account with Claude Code access
- `envsubst`, which reads `.env`. On macOS:

  ```bash
  brew install gettext && brew link --force gettext
  ```

  On Debian/Ubuntu:

  ```bash
  sudo apt-get install gettext-base
  ```

## Initialize

Run this once from the project's root, on your host (not inside a sandbox):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/init.sh)"
```

It asks everything up front, then creates:

- `.claude/sandbox/` scripts: `build.sh`, `run.sh`, `start.sh`, `restart.sh`, `sync.sh` and `plugin.sh`. They wrap the launcher and use the repo name as the image tag. A script you have not edited is updated on each run; an edited one is only asked about when the template changed (Enter shows the diff, `m` merges your edits, and a replaced file is backed up to `<name>.bak.<timestamp>`).
- `.claude/sandbox/ref`, which pins the launcher to a commit of this repo, so a change to `main` reaches the project only when you run `init.sh` again. `CS_REF=<commit|tag|branch>` chooses what to pin; `CS_REF=latest` pins nothing and removes an existing pin, so the project follows `main`; put `export CS_REF=latest` in `.envrc-cs` to keep that across `init.sh` runs. To pin once without editing anything:

  ```bash
  CS_REF=latest /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/init.sh)"
  ```
- `.envrc-cs`, with the launcher settings (each with a comment saying what it does), and a `source_env .envrc-cs` line in `.envrc`; and a marked block of `CS_` entries in `.env`. Entries are kept in alphabetical order, and nothing else in either file is touched (see [Configure](#configure)).
- Optionally: a fine-grained GitHub token for `git` and `gh` in the sandbox, a package-only `ghcr.io` login, and a `main` branch ruleset (needs `gh` logged in as a repo admin).

`--yes` and `--no` answer the yes/no questions for runs with nobody at the keyboard; the token and registry login need a pasted secret, so both skip them. From the one-liner, put them after the command string with a placeholder first:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/init.sh)" init.sh --yes
```

Commit `.claude/sandbox/` (including `ref`). Run `init.sh` again to update the scripts or move the pin.

## Configure

Every setting is documented where it lives:

- **`.envrc-cs`**: launcher settings (`CS_*`: image, docker flags, limits, and so on). `init.sh` adds `source_env .envrc-cs` to `.envrc`, so direnv loads it, and adds `.envrc*` to `.git/info/exclude` (local to the clone) so neither is committed by accident; without direnv, `source .envrc-cs` in your shell.
- **`.env`**: secrets and variables passed into the container. `init.sh` keeps `CS_GITHUB_TOKEN`, `CS_GITHUB_HOST` and your user-config repo and token in a marked block; add anything else the project needs outside it. For GitHub Enterprise (Server, or Cloud with a `*.ghe.com` tenant) `init.sh` takes the host from the origin remote and writes it as `CS_GITHUB_HOST`; the token, `git`, `gh` and the user-config clone then use that host. The launcher scripts themselves still come from github.com, and the `ghcr.io` login is skipped off github.com (set `CS_IMAGE_REPO` for your own registry).
- **`.claude/sandbox/plugin.sh`**: the tools to install in the project's image. Run `.claude/sandbox/build.sh` after changing it. See [Plugins and custom images](docs/plugins.md).

## Run

Interactive, with Claude Code running in your terminal:

```bash
.claude/sandbox/run.sh
```

In the background, with the container detached:

```bash
.claude/sandbox/start.sh
```

Rebuild the image, stop the container and start it again:

```bash
.claude/sandbox/restart.sh
```

`build.sh` and `restart.sh` push the image to `CS_IMAGE_REPO`. To build it for this machine only, pass `--no-push` (first, for `restart.sh`; the rest still goes to `claude`):

```bash
.claude/sandbox/restart.sh --no-push
```

Arguments go to `claude`:

```bash
.claude/sandbox/run.sh --continue
```

For `start.sh` they apply to the container it starts; a container that is already running is left alone. `restart.sh` reuses the arguments of the container it replaces unless you pass new ones, and reads `.env` fresh, so it is also how a running sandbox picks up a changed token.

The background container is named `cs-<repo-name>` (replace `<repo-name>` below). Attach to it, and detach again with ctrl-p ctrl-q:

```bash
docker attach cs-<repo-name>
```

Stop it:

```bash
docker stop cs-<repo-name>
```

`start.sh` restarts it after a docker or host restart until you `docker stop` it (add your own `--restart` to `CS_DOCKER_FLAGS` to change that). To use another image, for example a language-pinned one:

```bash
CS_IMAGE_TAG=go-1.25.10 .claude/sandbox/run.sh
```

## More

- [Rules, memories and Claude state](docs/user-scope.md): project and user scope, and what each sandbox sees of `~/.claude`
- [Plugins and custom images](docs/plugins.md)
- [Security](docs/security.md): read-only files, tokens, merging and CI, network egress
- [Development](docs/development.md)

## License

MIT
