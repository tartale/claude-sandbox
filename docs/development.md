# Development

The repository is organized by where the code runs:

```
cs                  the command (see README); needs no installation
host/               runs on your machine: init, build, run, start, restart, sync, network, the launcher
container/          baked into the image: Dockerfile, entrypoint and the scripts it installs
plugins/            language and tool plugins
tests/              bash tests
```

Run the tests in `tests/` with `./cs test`. CI runs them on every pull request. Each file covers one area:

| File | Covers |
|---|---|
| `cs.sh` | the command's help, dispatch and download |
| `host.sh` | the scripts behind `cs build` and `cs run` |
| `launcher.sh` | the launcher, with a stubbed `docker` (no daemon needed); the `.env` expansion tests need `envsubst` and are skipped without it |
| `init.sh` | `host/init.sh` in a scratch git project on a pty with no network: the stubs it generates and how it treats files you edited |
| `build-image.sh` | build arguments and secrets, with stubbed `docker` and `npm`; workflow actions pinned by SHA |
| `network.sh` | `host/network.sh` against stubbed `docker`, `iptables` and `ip`, a directory standing in for the firewall chain |
| `owner.sh` | `cs pr` and `cs release`, against a stubbed `gh` |
| `github-config.sh` | the git config and `gh` environment the container sets up for each GitHub host |
| `user-pull.sh` | `claude-user-pull` and `claude-user-sync`, against a local bare repo |
| `shellcheck.sh` | every script, and what `init.sh` writes, for unquoted expansions (SC2086), which CI's warning-level job does not report |

Other commands: `cs image` builds the base image for this machine; `cs push` and `cs all` build and push it, and every language variant, for amd64 and arm64; `cs tags` adds version tags; `cs clean` removes the local image. `cs --help` lists them all.
