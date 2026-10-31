# Plugins and custom images

Commands use `cs`: `./cs` from a checkout, or the one-liner from the [README](../README.md#the-cs-command). Examples run `cs build` directly to show its variables; in a project, `.claude/sandbox/build.sh` runs it for you.

## Building a custom image

Put the project's plugins in `.claude/sandbox/plugin.sh`, then build:

```bash
.claude/sandbox/build.sh
```

This builds the project image and pushes it to `CS_IMAGE_REPO:CS_IMAGE_TAG`; `run.sh` and `start.sh` use the same tag. `--no-push` builds for this machine only (`cs build --no-push` anywhere).

`cs build` also works alone, without a checkout or project. Launch the result by setting `CS_IMAGE_TAG` to match:

```bash
CS_IMAGE_TAG=my-sandbox cs build
CS_IMAGE_TAG=my-sandbox .claude/sandbox/run.sh
```

### Build settings

`cs build` reads these from the environment, so the project's `.envrc-cs` (where each is documented) applies: `CS_IMAGE_REPO`, `CS_IMAGE_TAG`, `CS_LANGUAGE_VERSIONS` (`"go-1.25.10"`-style pins) and `CLAUDE_VERSION`. `PLUGINS` (a built-in plugin name, local path or URL) is set by `build.sh` to `plugin.sh`; set it yourself when calling `cs build` directly, and it overrides `plugin.sh`.

```bash
PLUGINS=python3 CS_IMAGE_TAG=my-python cs build                                    # built-in plugin
PLUGINS=go CS_LANGUAGE_VERSIONS="go-1.24.0" CS_IMAGE_TAG=go-1.24 cs build          # with a version pin
PLUGINS=./my-tools.sh CS_IMAGE_TAG=my-tools cs build                               # local script
PLUGINS=https://example.com/my-tools.sh CS_IMAGE_TAG=my-tools cs build             # remote script
```

To build from another npm registry, set `CS_NPM_REGISTRY` (its URL, with `https://`). If it needs credentials, put them in an npmrc file on the host and set `CS_NPMRC` to its path. The file is mounted as a BuildKit secret, so the token is not in the image or its history. Both apply to Claude Code and to the plugins' `npm install` steps. In `.envrc-cs`:

```bash
export CS_NPM_REGISTRY="https://registry.example.com/npm/"
export CS_NPMRC="${HOME}/.npmrc"
```

The npmrc holds a line such as `//registry.example.com/npm/:_authToken=<token>`.

## Built-in plugins

Plugins are shell scripts that install tools into the image. Built-ins resolve by name from any directory (`PLUGINS=go`, `PLUGINS=docker`).

Languages (`plugins/languages/`), each defaulting to the latest stable version:

| Plugin | Installs | Version pin |
|---|---|---|
| `cpp` | `build-essential`, `clang`, `cmake`, `gdb`, `ninja`, `valgrind` | `cpp-<clang-major>`, e.g. `cpp-17` |
| `go` | Go toolchain | `go-<version>`, e.g. `go-1.25.10` |
| `java` | OpenJDK, Maven | `java-<major>`, e.g. `java-21` |
| `python2` | `pip`, `venv`, `pipx`, `uv` | `python-<version>`, e.g. `python-3.13.2` |
| `python3` | `pip`, `venv`, `pipx`, `uv` | `python3-<version>`, e.g. `python3-3.13.2` |
| `react` | Chromium and Firefox, TypeScript, pnpm, Vite, create-next-app, ESLint, Prettier | none |
| `ruby` | Ruby, Bundler | `ruby-<version>`, e.g. `ruby-3.3.0` |
| `rust` | Rust via rustup (`cargo`, `rustc`, `rustfmt`, `clippy`) | `rust-<version>`, e.g. `rust-1.78.0` |
| `typescript` | TypeScript, `ts-node`, `tsx`, `@types/node` | `typescript-<version>`, e.g. `typescript-5.4.0` |

Tools (`plugins/tools/`):

| Plugin | Installs |
|---|---|
| `docker` | Docker CLI (client only), Buildx and Compose |
| `playwright` | Playwright CLI and test runner, Chromium, Firefox and their system libraries |

### Pinning a language version

`CS_LANGUAGE_VERSIONS` is a space-separated list of `<language>-<version>` entries; each plugin takes only its own, and installs the latest stable version when it has none:

```bash
PLUGINS=go CS_LANGUAGE_VERSIONS="go-1.25.10" CS_IMAGE_TAG=go-1.25.10 cs build
```

- **cpp**: the clang major version, from the [LLVM apt repo](https://apt.llvm.org).
- **java**: only major versions in Debian apt (`11`, `17`, `21`).
- **ruby**: compiled from source with `ruby-build`, so builds take longer.

### Docker

The plugin installs only the client. To reach the host daemon, bind-mount its socket:

```bash
CS_DOCKER_FLAGS="-v /var/run/docker.sock:/var/run/docker.sock" .claude/sandbox/run.sh
```

This gives the sandbox root on the host (it can start privileged containers), so the launcher warns when it sees the mount. It is an accepted risk, not a safeguarded feature: nothing filters what the agent asks the daemon to do. Mount the socket only in a sandbox whose job needs it (for example an SRE sandbox that restarts the service it owns), never in a general development sandbox, and only for a project you trust. The launch scripts in `.claude/sandbox` are mounted read-only, so the agent cannot add the mount to a launch that lacked it.

### Playwright

The plugin bakes in the browsers and the system libraries they need, which a plain `npm install playwright` in a running sandbox cannot do (it needs root). Browsers land in `/ms-playwright` with `PLAYWRIGHT_BROWSERS_PATH` exported for every shell, so they resolve under any uid. They run headless natively; no Xvfb wrapper is needed. Browser revisions follow the Playwright version, so pin it to match the project's dependency:

```bash
PLUGINS=playwright CS_LANGUAGE_VERSIONS="playwright-1.55.0" CS_IMAGE_TAG=my-playwright cs build
```

## Several plugins

Point `PLUGINS` at a directory of `.sh` scripts to run them all in alphabetical order. Prefix names with numbers to control the order (`01-go.sh`, `02-rust.sh`):

```bash
PLUGINS=./my-plugins/ CS_IMAGE_TAG=my-tag cs build
```

From a checkout, `./cs image` builds from a local plugin path in the same way, for example `PLUGINS=plugins/languages/go.sh CS_IMAGE_TAG=my-tag ./cs image`.

## Writing your own plugin

A plugin is any executable shell script. It runs as root during `docker build`, so `apt-get` works without `sudo`:

```bash
cat > my-tools.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
apt-get update && apt-get install -y my-tool && rm -rf /var/lib/apt/lists/*
EOF
```

`PLUGINS_DIR` points at the root of the `plugins/` directory, so a plugin can run built-in ones. A Go and React stack:

```bash
cat > go-react.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

bash "$PLUGINS_DIR/languages/go.sh"
bash "$PLUGINS_DIR/languages/react.sh"
EOF
PLUGINS=./go-react.sh CS_IMAGE_TAG=go-react CS_LANGUAGE_VERSIONS="go-1.25.10" cs build
```

Sourced plugins still respect `CS_LANGUAGE_VERSIONS`.

## Runtime plugins

`PLUGINS` also works at run time with `host/claude-sandbox.sh`. The script (or directory) is bind-mounted into the container and run before Claude starts, so setup steps need no rebuild:

```bash
PLUGINS=plugins/languages/python2.sh ./host/claude-sandbox.sh
```
