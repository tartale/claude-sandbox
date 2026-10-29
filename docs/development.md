# Development

Run the bash tests in `tests/` with:

```bash
make test
```

`launcher.sh` exercises the launcher with a stubbed `docker` (no daemon needed). `init.sh` runs `init.sh` in a scratch git project on a pty, with no network, to check the stubs it generates and how it treats files you edited. `build-image.sh` checks the build arguments and secrets with stubbed `curl`, `docker` and `npm`. `network.sh` runs the script against stubbed `docker`, `iptables` and `ip`, with a directory standing in for the firewall chain. `github-config.sh` covers the git config and `gh` environment the container sets up for each GitHub host. `user-pull.sh` covers `claude-user-pull` and `claude-user-sync` against a local bare repo. The expansion tests need `envsubst` and are skipped without it. CI runs them on every pull request.
