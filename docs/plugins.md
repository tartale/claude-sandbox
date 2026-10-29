# Plugins and custom images

## Building a custom image

Put the project's plugins in `.claude/sandbox/plugin.sh`, then build:

```bash
.claude/sandbox/build.sh
```

It builds the project image and pushes it to `CS_IMAGE_REPO:CS_IMAGE_TAG`; `run.sh` and `start.sh` use the same tag. `--no-push` builds without pushing, for an image only this machine uses (`build-image.sh` takes it too):

```bash
.claude/sandbox/build.sh --no-push
```

 The stub wraps the `build-image.sh` one-liner, which also works on its own, with no repo checkout:

```bash
CS_IMAGE_TAG=my-sandbox /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

Then launch it by setting `CS_IMAGE_TAG` to match:

```bash
CS_IMAGE_TAG=my-sandbox .claude/sandbox/run.sh
```

The examples below call `build-image.sh` directly to show its environment variables.

### Build settings

`build-image.sh` reads these from the environment, so the stubs pick up the ones in `.envrc-cs` (each is documented there): `CS_IMAGE_REPO`, `CS_IMAGE_TAG`, `CS_LANGUAGE_VERSIONS` (`"go-1.25.10"`-style pins) and `CLAUDE_VERSION`. `PLUGINS` (a built-in plugin name, local path or URL) is set by `build.sh` to `plugin.sh`; set it yourself when calling `build-image.sh` directly.

A built-in language plugin:

```bash
PLUGINS=python3 CS_IMAGE_TAG=my-python /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

A built-in plugin with a version pin:

```bash
PLUGINS=go CS_LANGUAGE_VERSIONS="go-1.24.0" CS_IMAGE_TAG=go-1.24 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

A local custom plugin script:

```bash
PLUGINS=./my-tools.sh CS_IMAGE_TAG=my-tools /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

A remote custom plugin script:

```bash
PLUGINS=https://example.com/my-tools.sh CS_IMAGE_TAG=my-tools /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

To build from another npm registry, set `CS_NPM_REGISTRY` (its URL, with the `https://`). If it needs credentials, put them in an npmrc file on the host and set `CS_NPMRC` to its path. The file is mounted as a BuildKit secret, so the token is not in the image or its history. Both apply to Claude Code and to the plugins' `npm install` steps. For example, in `.envrc-cs`:

```bash
export CS_NPM_REGISTRY=https://registry.example.com/npm/
export CS_NPMRC=$HOME/.npmrc
```

where the npmrc holds a line such as `//registry.example.com/npm/:_authToken=<token>`.

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
CS_DOCKER_FLAGS="-v /var/run/docker.sock:/var/run/docker.sock" .claude/sandbox/run.sh
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
PLUGINS=playwright CS_LANGUAGE_VERSIONS="playwright-1.55.0" CS_IMAGE_TAG=my-playwright ./build-image.sh
```

### Using a single plugin

Pass a built-in name or path via `PLUGINS`:

With no repo checkout:

```bash
PLUGINS=go CS_IMAGE_TAG=my-go /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

With a local repo checkout:

```bash
PLUGINS=plugins/languages/go.sh CS_IMAGE_TAG=my-tag make image
```

### Pinning a language version

Pass `CS_LANGUAGE_VERSIONS` as a space-separated list of `<language>-<version>` entries. Each plugin extracts only its own entry:

With no repo checkout:

```bash
PLUGINS=go CS_LANGUAGE_VERSIONS="go-1.25.10" CS_IMAGE_TAG=go-1.25.10 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

With a local repo checkout:

```bash
PLUGINS=plugins/languages/go.sh CS_IMAGE_TAG=go-1.25.10 CS_LANGUAGE_VERSIONS="go-1.25.10" make image
```

When a plugin's entry is absent from `CS_LANGUAGE_VERSIONS`, it installs the latest stable version.

Notes:
- **cpp**: version refers to the clang major version installed from the [LLVM apt repo](https://apt.llvm.org)
- **java**: only major versions available in Debian apt are supported (e.g. `11`, `17`, `21`)
- **ruby**: compiles from source via `ruby-build` — expect longer build times

### Using multiple plugins

Point `PLUGINS` at a local directory of `.sh` scripts to run all of them, in alphabetical order:

With no repo checkout:

```bash
PLUGINS=./my-plugins/ CS_IMAGE_TAG=my-tag /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

With a local repo checkout:

```bash
PLUGINS=plugins/languages CS_IMAGE_TAG=my-tag make image
```

Prefix filenames with numbers to control order when it matters (`01-go.sh`, `02-rust.sh`, …).

### Writing your own plugin

A plugin is any executable shell script. Create one anywhere and point `PLUGINS` at it:

```bash
cat > my-tools.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
apt-get update && apt-get install -y my-tool && rm -rf /var/lib/apt/lists/*
EOF
```

The script runs as root during `docker build`, so standard `apt-get` installs work without `sudo`.

### Composing built-in plugins

`PLUGINS_DIR` is pre-populated with the path to the root of the `plugins/` directory. A custom plugin can use it to source built-in language plugins by path.

**Example — a Go + React stack.** Create `go-react.sh`:

```bash
cat > go-react.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

bash "$PLUGINS_DIR/languages/go.sh"
bash "$PLUGINS_DIR/languages/react.sh"
EOF
```

Build it with no repo checkout:

```bash
PLUGINS=./go-react.sh CS_IMAGE_TAG=go-react /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

Or with a local repo checkout:

```bash
PLUGINS=./go-react.sh CS_IMAGE_TAG=go-react make image
```

Each sourced plugin respects `CS_LANGUAGE_VERSIONS`, so you can still pin versions:

```bash
PLUGINS=./go-react.sh CS_IMAGE_TAG=go-react \
  CS_LANGUAGE_VERSIONS="go-1.25.10" /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
```

### Runtime plugins

`PLUGINS` also works at runtime with `claude-sandbox.sh`. The script (or directory) is bind-mounted into the container and executed before Claude starts, letting you run setup steps without rebuilding the image:

```bash
PLUGINS=plugins/languages/python2.sh ./claude-sandbox.sh
```
