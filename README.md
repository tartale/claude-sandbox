# claude-sandbox

Runs [Claude Code](https://github.com/anthropics/claude-code) in a Docker container, mounting your current directory as the workspace. This gives Claude a sandboxed environment to read and modify files without touching the rest of your system.

The image is published to the GitHub Container Registry as [`ghcr.io/tartale/claude-sandbox`](https://github.com/tartale/claude-sandbox/pkgs/container/claude-sandbox).

Your Claude credentials (`~/.claude` and `~/.claude.json`) are bind-mounted into the container so you stay logged in.

The container runs as a user matching your host UID and GID, so files written to the workspace are owned by you. Your shell's umask is also applied inside the container so new files get the expected permissions. Note that on macOS, Docker Desktop runs containers in a Linux VM, so the host umask has no effect — the default umask of the container will be used instead.

## Requirements

- Docker
- An Anthropic account with Claude Code access

## Usage

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/claude-sandbox.sh)"
```

Run this from any project directory. Claude Code will start inside a container with that directory as `/workspace`. The launcher pulls `ghcr.io/tartale/claude-sandbox:latest` automatically; to pre-pull it:

```bash
docker pull ghcr.io/tartale/claude-sandbox:latest
```

### Passing arguments to Claude

Use the pipe form with `-s --` to forward arguments to `claude`:

```bash
curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/claude-sandbox.sh | bash -s -- --resume
```

Any flags after `--` are passed directly to the `claude` invocation inside the container.

### Using a specific image tag

To use a language-pinned image:

```bash
CS_IMAGE_TAG=go-1.25.10 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/claude-sandbox.sh)"
```

## Building a custom image

To build a custom image with plugins, run this one-liner — no repo checkout needed:

```bash
CS_IMAGE_TAG=my-sandbox /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

Then launch it by setting `CS_IMAGE_TAG` to match:

```bash
CS_IMAGE_TAG=my-sandbox /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/claude-sandbox.sh)"
```

### Build environment variables

| Variable | Description |
|---|---|
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

All plugins default to the latest stable version. See [Pinning a language version](#pinning-a-language-version) for details.

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

## Environment variables

| Variable | Description |
|---|---|
| `CS_IMAGE_TAG` | Tag of the `ghcr.io/tartale/claude-sandbox` image to use (default: `latest`) |
| `CS_ENV_FILE` | Path to an env file to pass into the container (default: `.env`) |
| `LANGUAGE_VERSIONS` | Space-separated list of language versions in `<language>-<version>` format (e.g. `"go-1.25.10"`). Each plugin extracts its own entry; omitted plugins default to latest stable. |
| `PLUGINS` | Path to a plugin script or directory of plugin scripts to install |

### Passing environment variables into the container

If a `.env` file exists in the current directory, it is passed to the container via `--env-file`. Use this to inject secrets or project-specific configuration:

```bash
# .env
GITHUB_TOKEN=ghp_...
MY_API_KEY=...
```

The `.env` file follows standard `KEY=VALUE` format. Variables not listed in the file are not passed to the container.

To use a different file name, set `CS_ENV_FILE`:

```bash
CS_ENV_FILE=.env.sandbox /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/claude-sandbox.sh)"
```

## License

MIT
