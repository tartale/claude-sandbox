# Development

The repository is organized by where the code runs:

```
cs                  the command (see README); needs no installation
host/               runs on your machine: init, build, run, start, restart, sync, network, the launcher
container/          baked into the image: Dockerfile, entrypoint and the scripts it installs
plugins/            language and tool plugins
tests/              bash tests
```

Run the bash tests in `tests/` with:

```bash
./cs test
```

`launcher.sh` exercises the launcher with a stubbed `docker` (no daemon needed). `init.sh` runs `host/init.sh` in a scratch git project on a pty, with no network, to check the stubs it generates and how it treats files you edited. `cs.sh` checks the command's help, dispatch and download. `host.sh` covers the scripts behind `cs build` and `cs run`. `build-image.sh` checks the build arguments and secrets with stubbed `docker` and `npm`. `network.sh` runs `host/network.sh` against stubbed `docker`, `iptables` and `ip`, with a directory standing in for the firewall chain. `shellcheck.sh` checks every script (and what `init.sh` writes) for unquoted expansions, SC2086, which CI's warning-level job does not report. `github-config.sh` covers the git config and `gh` environment the container sets up for each GitHub host. `user-pull.sh` covers `claude-user-pull` and `claude-user-sync` against a local bare repo. The expansion tests need `envsubst` and are skipped without it. CI runs them on every pull request.

The other development commands: `cs image` builds the base image for this machine, `cs push` and `cs all` build and push it (and every language variant) for amd64 and arm64, `cs tags` adds version tags, `cs clean` removes the local image. Run `cs --help` for the list.
