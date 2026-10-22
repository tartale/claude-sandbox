# Security

What the sandbox protects, and what it leaves to you.

## What the agent can and cannot change

The env file, `.envrc`, `.git/config`, `.git/hooks`, `.claude/sandbox/ref` and `.claude/sandbox/{build,restart,run,start,sync}.sh` are mounted read-only inside the container. They run on the host later (when you launch, `cd` with direnv, or commit), and an agent must not be able to plant code in them. Edit them from the host.

- `.claude/sandbox/plugin.sh` stays writable so the agent can maintain the project's dependencies. It only runs inside the image build, but read its `git diff` before running `build.sh`.
- `.git/config` is read-only, so a session cannot add an alias, `core.fsmonitor` or `core.sshCommand` that your host git would run. Inside the container git is told not to record upstream tracking (`branch.autoSetupMerge=false`), so `git push -u` still pushes but prints an error about the config it cannot write, and `git branch --set-upstream-to`, `git remote add` and `git config` fail. Do those on the host; git replaces the file on write, so a running container keeps the old `.git/config` until it restarts.
- Other files that run on the host later (`Makefile` targets, test and package scripts) stay writable, so read `git diff` before running host-side tooling on a checkout an agent has touched.
- The container runs with all capabilities dropped except `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID` and `SETGID`, and with `no-new-privileges`.

## GitHub token

`CS_GITHUB_TOKEN` (in `.env`) lets `git` and `gh` authenticate inside the container. Whatever the token can do, the agent can do, so `init.sh` walks you through a [fine-grained token](https://github.com/settings/personal-access-tokens) limited to the one repository, with Contents, Pull requests and Issues write access and no Administration or Workflows permission. It checks push access, no Administration and no other private repos; it cannot probe the Workflows permission, so confirm that is off on the token page.

## Merging and CI

Nothing technical stops a session from merging its own pull request. The sandbox token has Contents and Pull requests write access and acts as your account, so GitHub will not let you approve what it opens, and the ruleset `init.sh` creates requires a PR but no approvals and no status checks. "Do not merge without approval" is a rule you give the agent, not one GitHub enforces. A real gate needs a second identity that does the merging or approving (a bot account with its own token, or a paid plan for reviews on a private repo). Short of that:

- add required status checks (for example `test`) to the ruleset once CI exists, so red code cannot merge;
- CI runs what the PR contains, including `plugin.sh`, the Dockerfile and the workflows, so keep registry and deploy secrets out of workflows that run on pull requests, and build and push images only from `main` or tags (this repo's `release.yml` runs on tags only);
- give PR workflows read-only `GITHUB_TOKEN` permissions (`permissions: contents: read`); the sandbox token has no `workflow` scope, so a session cannot push workflow files, and you add this yourself;
- read the diff of `plugin.sh`, the Dockerfile, `.github/` and `.claude/sandbox/` before merging.

## Network egress

The container can reach any host, including the other machines on your LAN. Anything the session can read (the project token, the user-config token, the Claude login) can therefore be sent out. Limiting what the container can reach has to happen outside it: the sandbox has no `NET_ADMIN` and cannot change its own rules.

The launcher sets none of this up, and the commands below are starting points that have not been run against your network. Pick the steps that match what you want to protect:

| Goal | Steps | Strength |
|---|---|---|
| Keep the container off your LAN (router, NAS admin page, other machines) | [1](#1-give-the-sandboxes-their-own-network) and [2](#2-block-the-lan-linux-host-or-nas) | Blocks the LAN; the internet stays open |
| Allow only the hosts the session needs | [1](#1-give-the-sandboxes-their-own-network) and [3](#3-allow-only-named-hosts-at-the-router) | Strongest; needs a router or firewall that filters by hostname |
| A quick filter with no network changes | [4](#4-a-filtering-resolver) | Weakest; a session that connects by IP address skips it |

### 1. Give the sandboxes their own network

Rules can then name the sandboxes' address range:

```bash
docker network create --subnet 172.30.0.0/24 claude-sandbox
```

Launch with `CS_DOCKER_FLAGS="--network claude-sandbox"` (set it in `.envrc`).

### 2. Block the LAN (Linux host or NAS)

Rules in the `DOCKER-USER` chain run before Docker's own. Drop the private ranges, and let DNS through to your resolver, so the session reaches the internet but not machines on your network:

```bash
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 10.0.0.0/8 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 172.16.0.0/12 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 192.168.0.0/16 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d <resolver-ip> -p udp --dport 53 -j ACCEPT
```

The last rule is inserted last, so it is evaluated first. Docker Desktop (macOS, Windows) has no host `iptables` to edit; use the router (step 3) instead.

### 3. Allow only named hosts, at the router

Container traffic leaves the host under the host's address, so a router rule cannot tell it from the host's own traffic. Give the sandbox its own LAN address with a `macvlan` or `ipvlan` network instead of the bridge in step 1:

```bash
docker network create -d macvlan --subnet ... --gateway ... -o parent=eth0 claude-sandbox
```

A macvlan container and its host cannot reach each other without extra setup. A router or firewall that filters by hostname (OPNsense, pfSense or OpenWrt aliases, or per-client DNS filtering in Pi-hole or AdGuard Home) can then allow `github.com`, `api.github.com`, `api.anthropic.com` and your package registries, and block the rest.

### 4. A filtering resolver

Point the container at a resolver that blocks what you don't want, with `CS_DOCKER_FLAGS="--dns <ip>"`. It is the cheapest step and the weakest: a session that connects by IP address skips it.
