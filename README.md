# claude-sandbox

Runs [Claude Code](https://github.com/anthropics/claude-code) in a Docker container with your project mounted at `/workspace`, so Claude can read and modify files without touching the rest of your system. The container runs as your UID and GID, so files it writes are yours.

## Requirements

- Docker
- An Anthropic account with Claude Code access
- `envsubst` (macOS: `brew install gettext && brew link --force gettext`; Debian/Ubuntu: `sudo apt-get install gettext-base`), which reads `.env`

## Initialize

Run this once from the project's root, on your host (not inside a sandbox):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/init.sh)"
```

It asks everything up front, then creates:

- `.claude/sandbox/` scripts: `build.sh`, `run.sh`, `start.sh`, `restart.sh`, `sync.sh` and `plugin.sh`. They wrap the launcher and use the repo name as the image tag. A script you have not edited is updated on each run; an edited one is only asked about when the template changed (Enter shows the diff, `m` merges your edits, and a replaced file is backed up to `<name>.bak.<timestamp>`).
- `.claude/sandbox/ref`, which pins the launcher to a commit of this repo, so a change to `main` reaches the project only when you run `init.sh` again. `CS_REF=<commit|tag|branch>` chooses what to pin; `CS_REF=latest` pins nothing and removes an existing pin, so the project follows `main`. Put `export CS_REF=latest` in `.envrc-cs` to keep that across `init.sh` runs.
- `.envrc-cs`, with the launcher settings (each with a comment saying what it does), and a `source_env .envrc-cs` line in `.envrc`; and a marked block of `CS_` entries in `.env`. Entries are kept in alphabetical order, and nothing else in either file is touched (see [Configure](#configure)).
- Optionally: a fine-grained GitHub token for `git` and `gh` in the sandbox, a package-only `ghcr.io` login, and a `main` branch ruleset (needs `gh` logged in as a repo admin).

`--yes` and `--no` answer the yes/no questions for runs with nobody at the keyboard; the token and registry login need a pasted secret, so both skip them. From the one-liner, put them after the command string with a placeholder first: `/bin/bash -c "$(curl -fsSL .../init.sh)" init.sh --yes`.

Commit `.claude/sandbox/` (including `ref`). Run `init.sh` again to update the scripts or move the pin.

## Configure

Every setting is documented where it lives:

- **`.envrc-cs`**: launcher settings (`CS_*`: image, docker flags, limits, and so on). `init.sh` adds `source_env .envrc-cs` to `.envrc`, so direnv loads it; without direnv, `source .envrc-cs` in your shell.
- **`.env`**: secrets and variables passed into the container. `init.sh` keeps `CS_GITHUB_TOKEN` and your user-config repo and token in a marked block; add anything else the project needs outside it.
- **`.claude/sandbox/plugin.sh`**: the tools to install in the project's image. Run `.claude/sandbox/build.sh` after changing it. See [Plugins and custom images](docs/plugins.md).

## Run

```bash
.claude/sandbox/run.sh      # interactive: Claude Code runs in your terminal
.claude/sandbox/start.sh    # background: the container runs detached
.claude/sandbox/restart.sh  # rebuild the image, stop the container, start it again
```

Arguments go to `claude`: `.claude/sandbox/run.sh --continue`. For `start.sh` they apply to the container it starts; a container that is already running is left alone. `restart.sh` reuses the arguments of the container it replaces unless you pass new ones, and reads `.env` fresh, so it is also how a running sandbox picks up a changed token.

The background container is named `cs-<repo-name>`:

```bash
docker attach cs-<repo-name>   # detach again with ctrl-p ctrl-q
docker stop cs-<repo-name>
```

`start.sh` restarts it after a docker or host restart until you `docker stop` it (add your own `--restart` to `CS_DOCKER_FLAGS` to change that). To use another image, for example a language-pinned one: `CS_IMAGE_TAG=go-1.25.10 .claude/sandbox/run.sh`.

## More

- [Rules, memories and Claude state](docs/user-scope.md): project and user scope, and what each sandbox sees of `~/.claude`
- [Plugins and custom images](docs/plugins.md)
- [Security](docs/security.md): read-only files, tokens, merging and CI, network egress
- [Development](docs/development.md)

## License

MIT
