# Network isolation

Part of [Security](security.md). By default the container can reach any host, including your LAN. The sandbox cannot change its own rules (no `NET_ADMIN`), so limits go on the host or the router. The launcher sets none of this up; `cs network` does, once per host.

Commands use `./cs`; away from a checkout, use the one-liner from the [README](../README.md#the-cs-command).

| Goal | Setup | Strength |
|---|---|---|
| Keep the container off your LAN | [`bridge`](#bridge-block-the-lan) | Blocks the LAN; the internet stays open |
| Allow only the hosts the session needs | [`macvlan` or `ipvlan`](#macvlan-and-ipvlan-filter-at-the-router) plus router rules | Strongest; needs a router that filters by hostname |
| A quick filter, no network changes | [a filtering resolver](#a-filtering-resolver) | Weakest; connecting by IP address skips it |

`cs network` detects the interface, subnet, gateway and resolver from the host's default route, shows what it found and asks before creating anything. Re-running adds only what is missing. Each `setup` prints the line to put in `.envrc-cs`. It has been tested against stubs, not a real firewall or router. A worked, verified router setup is in [UniFi](unifi.md).

## Bridge: block the LAN

On a Linux host or NAS, as root:

```bash
sudo ./cs network setup bridge
```

It sets up:

- a `claude-sandbox` docker network for the sandboxes;
- `DOCKER-USER` rules that drop the sandbox's traffic to the private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and allow DNS to your resolver, so the session reaches the internet but not your network;
- `INPUT` rules that drop new connections from the sandbox to the host itself (ssh, web and admin ports), which the `DOCKER-USER` rules do not cover.

Limits:

- The rules do not survive a reboot (the docker network does). Run `setup bridge` again after one.
- A NAS firewall that rewrites `INPUT` can push the host rules down the chain. Run `./cs network check` after changing its settings.
- Docker Desktop (macOS, Windows) has no host `iptables`. Use the router instead.

## macvlan and ipvlan: filter at the router

Bridge traffic leaves the host under the host's address, so a router cannot tell it from the host's own. A `macvlan` or `ipvlan` network gives the sandbox its own LAN address. `--ip-range` is a slice your DHCP server does not hand out:

```bash
./cs network setup macvlan --ip-range 192.168.1.192/28
./cs network setup ipvlan --ip-range 192.168.1.192/28   # macvlan does not work over Wi-Fi
```

A router or firewall that filters by hostname (OPNsense, pfSense or OpenWrt aliases; Pi-hole or AdGuard Home per-client filtering) can then allow [the hosts below](#hosts-the-sandbox-needs) and block the rest. A macvlan container and its host cannot reach each other without extra setup.

On the LAN's own subnet this does not isolate the sandbox from other devices: that traffic goes through the switch, not the router. Give the sandbox its own VLAN (see [UniFi](unifi.md)).

## A filtering resolver

Point the container at a resolver that blocks what you do not want, in `.envrc-cs`:

```bash
export CS_DOCKER_FLAGS="--dns 192.168.1.1"
```

The cheapest setup and the weakest.

## Checking and removing

Check from a throwaway container that a LAN host and the host's ssh and web ports are blocked (bridge only; with macvlan or ipvlan the router decides), DNS works and the internet is reachable. Pass your router's address, or none to test the default gateway:

```bash
./cs network check 192.168.1.1
```

See what is set up, or undo it:

```bash
sudo ./cs network status
sudo ./cs network remove
```

An existing network under that name must match what you ask for (type, subnet, range), or `setup` stops and tells you to `remove` it first; that is also how you switch types. `--name`, `--subnet`, `--gateway`, `--parent`, `--resolver` and `--mode l2|l3` override detection; `--yes` skips the confirmation.

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
