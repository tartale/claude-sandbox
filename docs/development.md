# Development

`make test` runs the bash tests in `tests/`. `launcher.sh` exercises the launcher with a stubbed `docker` (no daemon needed); `init.sh` runs `init.sh` in a scratch git project on a pty, with no network, to check the stubs it generates and how it treats files you edited. The expansion tests need `envsubst` and are skipped without it. CI runs them on every pull request.
