# Network isolation

Part of [Security](security.md). By default the container can reach any host, including your LAN. The sandbox cannot change its own rules (no `NET_ADMIN`), so limits go on the host or the router. The launcher sets none of this up.

Commands use `./cs`; away from a checkout, use the one-liner from the [README](../README.md#the-cs-command).

| Goal | Steps | Strength |
|---|---|---|
| Keep the container off your LAN | [1](#1-give-the-sandboxes-their-own-network) and [2](#2-block-the-lan-linux-host-or-nas) | Blocks the LAN; the internet stays open |
| Allow only the hosts the session needs | [1](#1-give-the-sandboxes-their-own-network) and [3](#3-allow-only-named-hosts-at-the-router) | Strongest; needs a router that filters by hostname |
| A quick filter, no network changes | [4](#4-a-filtering-resolver) | Weakest; connecting by IP address skips it |

[`cs network`](#automating-steps-1-to-3) automates steps 1 to 3 (tested against stubs, not a real firewall or router). A worked, verified router setup is in [UniFi](unifi.md).

## 1. Give the sandboxes their own network

Rules can then name the sandboxes' address range:

```bash
docker network create --subnet 172.30.0.0/24 claude-sandbox
```

Launch with this flag (put it in `.envrc-cs` to keep it):

```bash
export CS_DOCKER_FLAGS="--network claude-sandbox"
```

## 2. Block the LAN (Linux host or NAS)

Rules in the `DOCKER-USER` chain run before Docker's own. Drop the private ranges and allow DNS to your resolver. Run as root, with `RESOLVER` set to your resolver's address (`192.168.1.1` is an example):

```bash
RESOLVER=192.168.1.1
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 10.0.0.0/8 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 172.16.0.0/12 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d 192.168.0.0/16 -j DROP
iptables -I DOCKER-USER -s 172.30.0.0/24 -d "$RESOLVER" -p udp --dport 53 -j ACCEPT
```

The DNS rule goes in last, so it is evaluated first. Docker Desktop (macOS, Windows) has no host `iptables`; use the router (step 3).

## 3. Allow only named hosts, at the router

Bridge traffic leaves the host under the host's address, so a router cannot tell it from the host's own. Give the sandbox its own LAN address with a `macvlan` or `ipvlan` network instead (subnet, gateway and parent interface are examples; use an address range your router does not hand out):

```bash
docker network create -d macvlan --subnet 192.168.1.0/24 --gateway 192.168.1.1 -o parent=eth0 claude-sandbox
```

A router or firewall that filters by hostname (OPNsense, pfSense or OpenWrt aliases; Pi-hole or AdGuard Home per-client filtering) can then allow [the hosts below](#hosts-the-sandbox-needs) and block the rest. A macvlan container and its host cannot reach each other without extra setup.

On the LAN's own subnet this does not isolate the sandbox from other devices: that traffic goes through the switch, not the router. Give the sandbox its own VLAN (see [UniFi](unifi.md)).

## 4. A filtering resolver

Point the container at a resolver that blocks what you do not want:

```bash
export CS_DOCKER_FLAGS="--dns 192.168.1.1"
```

The cheapest step and the weakest.

## Automating steps 1 to 3

`cs network` runs once per host. It detects the interface, subnet, gateway and resolver from the default route, shows what it found and asks before creating anything. Re-running adds only what is missing. Each setup prints the `CS_DOCKER_FLAGS` line for `.envrc-cs`.

Steps 1 and 2 on a Linux host or NAS (root). It also drops new connections from the sandbox to the host itself (ssh, web and admin ports), which a `DOCKER-USER` rule alone does not:

```bash
sudo ./cs network setup bridge
```

Step 3, a network with its own LAN addresses for a router to filter. `--ip-range` is a slice your DHCP server does not hand out:

```bash
./cs network setup macvlan --ip-range 192.168.1.192/28
./cs network setup ipvlan --ip-range 192.168.1.192/28   # macvlan does not work over Wi-Fi
```

Check from a throwaway container that a LAN host and the host's ssh and web ports are blocked (bridge only; with macvlan or ipvlan the router decides), DNS works and the internet is reachable. Pass your router's address, or none to test the default gateway:

```bash
./cs network check 192.168.1.1
```

See what is set up, or undo it:

```bash
sudo ./cs network status
sudo ./cs network remove
```

An existing network under that name must match what you ask for (type, subnet, range), or `setup` stops and tells you to `remove` it first; that is also how you switch types. `--name`, `--subnet`, `--gateway`, `--parent`, `--resolver` and `--mode l2|l3` override detection; `--yes` skips the confirmation. Bridge rules do not survive a reboot (the docker network does), so run `setup bridge` again after one. Host-side rules go in `INPUT`; a NAS firewall that rewrites `INPUT` can push them down the chain, so run `check` after changing its settings. Docker Desktop cannot do any of this.

## Hosts the sandbox needs

From [Anthropic's network requirements](https://code.claude.com/docs/en/network-config), plus what `git` and `gh` use. Match each host exactly: a rule that treats a bare domain as covering its subdomains makes a wildcard of it.

Required to run and sign in:

- `api.anthropic.com`
- `claude.ai`
- `platform.claude.com` (OAuth token exchange and refresh; without it Claude Code stops authenticating)

Optional, by feature:

- `sso.claude.com` (single sign-on)
- `mcp-proxy.anthropic.com` (MCP connectors from claude.ai; `ENABLE_CLAUDEAI_MCP_SERVERS=false` turns them off)
- `registry.npmjs.org` (plugin installs, `npx` MCP servers)
- `downloads.claude.ai` and `storage.googleapis.com` (plugin downloads)
- `raw.githubusercontent.com` (`/release-notes`)
- `code.claude.com` (documentation lookups)

Telemetry goes to `http-intake.logs.us5.datadoghq.com` and `browser-intake-us5-datadoghq.com`. Leave them blocked and set `DISABLE_TELEMETRY=1` or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` in `.env`.

For `git` and `gh`: `github.com`, `api.github.com`, `codeload.github.com` and `objects.githubusercontent.com`. On GitHub Enterprise, allow your `CS_GITHUB_HOST` instead (plus `api.<tenant>.ghe.com` for an Enterprise Cloud tenant), and keep `github.com` and `raw.githubusercontent.com` for the launcher scripts the stubs fetch.

## The DNS channel

Before connecting to `github.com`, the sandbox looks the name up, and the lookup goes to your gateway, which passes any name on to the internet's DNS servers. A hostile process can leak data in the names it asks for: a lookup of `c2VjcmV0.attacker-example.com` delivers `c2VjcmV0` to whoever runs that domain's name server, even though connecting to the site is blocked. It is slow (a few bytes per lookup) but it works. For code you review it is a minor risk, accepted and written down here.

To close it, run a small DNS server for the sandbox (for example dnsmasq on the NAS) that answers only your allowed names and refuses the rest. Point the sandbox at it with `--dns` in `CS_DOCKER_FLAGS`, and let the sandbox range use DNS only at that server. Domain-based firewall rules need the gateway to see the lookups; a server that forwards the allowed names to the gateway keeps that working, but test that the allowed hosts still resolve. Gateways that only filter by blocklist (UniFi included) cannot do this themselves; see [UniFi](unifi.md#dns).
