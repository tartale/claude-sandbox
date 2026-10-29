# Security

What the sandbox protects, and what it leaves to you.

## What the agent can and cannot change

The env file, `.envrc`, `.envrc-cs`, `.git/config`, `.git/hooks`, `.claude/sandbox/ref` and `.claude/sandbox/{build,restart,run,start,sync}.sh` are mounted read-only inside the container. They run on the host later (when you launch, `cd` with direnv, or commit), and an agent must not be able to plant code in them. Edit them from the host.

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

The launcher sets none of this up. [`network.sh`](#automating-steps-1-to-3) automates steps 1 to 3 (it has been tested against stubs, not against a real firewall or router), and the manual commands below are what it does. Pick the steps that match what you want to protect:

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

Launch with this flag; put it in `.envrc-cs` to keep it:

```bash
export CS_DOCKER_FLAGS="--network claude-sandbox"
```

### 2. Block the LAN (Linux host or NAS)

Rules in the `DOCKER-USER` chain run before Docker's own. Drop the private ranges, and let DNS through to your resolver, so the session reaches the internet but not machines on your network. Run these as root, with `RESOLVER` set to your resolver's address (`192.168.1.1` is an example):

```bash
RESOLVER=192.168.1.1
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 10.0.0.0/8 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 172.16.0.0/12 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 192.168.0.0/16 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d "$RESOLVER" -p udp --dport 53 -j ACCEPT
```

The last rule is inserted last, so it is evaluated first. Docker Desktop (macOS, Windows) has no host `iptables` to edit; use the router (step 3) instead.

### 3. Allow only named hosts, at the router

Container traffic leaves the host under the host's address, so a router rule cannot tell it from the host's own traffic. Give the sandbox its own LAN address with a `macvlan` or `ipvlan` network instead of the bridge in step 1. The subnet, gateway and parent interface below are examples; use your LAN's, and an address range the router does not hand out:

```bash
docker network create -d macvlan --subnet 192.168.1.0/24 --gateway 192.168.1.1 -o parent=eth0 claude-sandbox
```

A macvlan container and its host cannot reach each other without extra setup. A router or firewall that filters by hostname (OPNsense, pfSense or OpenWrt aliases, or per-client DNS filtering in Pi-hole or AdGuard Home) can then allow `github.com`, `api.github.com`, `api.anthropic.com` and your package registries, and block the rest.

### Automating steps 1 to 3

`network.sh` runs once per host, not per project. It detects the interface, subnet, gateway and resolver from the host's default route, shows what it found and asks before it creates anything. Re-running it only adds what is missing.

Steps 1 and 2 in one go, on a Linux host or NAS (needs root). Besides blocking your LAN, this drops new connections from the sandbox to the host itself (ssh, the web and admin ports), which a `DOCKER-USER` rule alone does not cover:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/network.sh)" network.sh setup bridge
```

Step 3: a network with its own LAN addresses, for a router or firewall to filter. `--ip-range` is a slice of your LAN that your DHCP server does not hand out (`192.168.1.192/28` is an example). Over a wired interface use macvlan:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/network.sh)" network.sh setup macvlan --ip-range 192.168.1.192/28
```

macvlan does not work over Wi-Fi; ipvlan does:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/network.sh)" network.sh setup ipvlan --ip-range 192.168.1.192/28
```

Each prints the `CS_DOCKER_FLAGS` line to put in `.envrc-cs`. Then check from a throwaway container that a LAN host and the host's own ssh and web ports are blocked (bridge only; with macvlan or ipvlan the router decides), DNS works and the internet is reachable. Pass your router's address, or leave it out to test the default gateway:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/network.sh)" network.sh check 192.168.1.1
```

To see what is set up, or to undo it:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/network.sh)" network.sh status
```

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/network.sh)" network.sh remove
```

A network that already exists under the name must match what you ask for (type, subnet and range); otherwise `setup` stops and tells you to `remove` it first, which is also how you switch between bridge, macvlan and ipvlan. `--name`, `--subnet`, `--gateway`, `--parent`, `--resolver` and `--mode l2|l3` override what it detects; `--yes` skips the confirmation. The bridge rules do not survive a reboot (the docker network does), so run `setup bridge` again after one. The host-side rules go in `INPUT`; a NAS whose firewall rewrites `INPUT` can push them down the chain, so run `check` after changing its firewall settings. Docker Desktop (macOS, Windows) cannot do any of this.

### 4. A filtering resolver

Point the container at a resolver that blocks what you don't want (`192.168.1.1` is an example):

```bash
export CS_DOCKER_FLAGS="--dns 192.168.1.1"
```

It is the cheapest step and the weakest: a session that connects by IP address skips it.
