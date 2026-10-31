# UniFi: a VLAN and gateway rules

Part of [Network isolation](network-isolation.md). This setup was verified from inside a sandbox: it could not reach the router's admin ports, the NAS or other LAN devices, or any internet host outside the allow-list.

Commands use `./cs`; away from a checkout, use the one-liner from the [README](../README.md#the-cs-command).

1. **Create an isolated network.** In UniFi, add a network with its own VLAN ID (here `6`, `10.0.6.0/24`), the "isolated" option on, and no DHCP.
2. **Tag the VLAN to the NAS port.** In the switch's Port Manager, keep the port's Native VLAN as the LAN the NAS is on, set Tagged VLAN Management to Custom and tick the new VLAN. The NAS stays where it is; only sandbox traffic is tagged.
3. **Create the docker network on the tagged sub-interface.** Docker creates `eth0.6` itself. `--ip-range` is a small block inside the VLAN (here `10.0.6.16/28`), which the rules below name. The kernel needs macvlan and 802.1q support; ipvlan is not available on every NAS kernel (Synology's 4.4 has none).

   ```bash
   ./cs network setup macvlan --parent eth0.6 --subnet 10.0.6.0/24 --gateway 10.0.6.1 --ip-range 10.0.6.16/28
   ```

4. **Launch on it, resolving through the gateway.** The gateway builds its domain-to-address table from the DNS answers it sees, so the sandbox's queries must go through it. In `.envrc-cs`:

   ```bash
   export CS_DOCKER_FLAGS="--network claude-sandbox --dns 10.0.6.1"
   ```

5. **Write the rules,** for the source `10.0.6.16/28`, in this order:
   - Allow DNS to the gateway (`10.0.6.1`, port 53).
   - Under Traffic & Firewall Rules, **Simple** (Advanced has no domain destinations), allow the [hosts the sandbox needs](network-isolation.md#hosts-the-sandbox-needs).
   - Drop everything else to the internet.
   - A separate rule for traffic to the gateway itself (LAN Local) that drops all of it except DNS. The internet rules do not cover this: without it the router's ssh and web UI answer.

6. **Verify from inside the sandbox,** replacing the NAS and device addresses with yours.

   ```bash
   for u in https://github.com https://api.anthropic.com https://platform.claude.com https://example.com; do printf '%s ' "$u"; curl -s -o /dev/null -m 6 -w '%{http_code}\n' "$u" || echo blocked; done
   ```

   The first three answer; `example.com` is blocked.

   ```bash
   for h in 10.0.1.1 10.0.6.1; do for p in 22 53 80 443; do timeout 3 bash -c "echo > /dev/tcp/$h/$p" 2>/dev/null && echo "$h:$p OPEN"; done; done
   ```

   Only port 53 is open.

   ```bash
   for h in 10.0.1.3 10.0.1.48; do for p in 22 80 445 5000 5001; do timeout 3 bash -c "echo > /dev/tcp/$h/$p" 2>/dev/null && echo "$h:$p OPEN"; done; done
   ```

   Nothing opens; the connections time out because the packets are dropped. Only TCP was probed. The rules are expected to cover UDP too, but that is untested.

## DNS

UniFi cannot close the [DNS channel](network-isolation.md#the-dns-channel):

- Content Filtering and Ad Blocking can redirect plain DNS (port 53) from a network to the gateway, and a firewall rule can block DNS over TLS (port 853). This setup already does the equivalent: the sandbox range reaches only the gateway's port 53.
- Content Filtering blocks listed domains and categories; its allowlist only exempts a name from a block, so it cannot be made allow-only.

This comes from UniFi's help center and forum as found by search, because the help pages could not be fetched when this was written: check it against your version. To close the channel anyway, use the resolver described in [Network isolation](network-isolation.md#the-dns-channel) and make the UniFi DNS rule allow the sandbox range to reach only that server.
