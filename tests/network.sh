#!/usr/bin/env bash
# Tests for network.sh with stubbed docker, iptables, ip, id and uname: a state directory
# stands in for the docker networks and the DOCKER-USER chain, so nothing touches the host.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

BIN="${WORK}/bin"; ST="${WORK}/state"
mkdir -p "${BIN}" "${ST}"
for f in /usr/bin/* /bin/*; do
    case "${f##*/}" in docker|iptables|ip|id|uname) continue ;; esac
    ln -sf "$f" "${BIN}/${f##*/}" 2>/dev/null || true
done
cat > "${BIN}/id" <<EOS
#!/bin/sh
echo "\${STUB_UID:-0}"
EOS
cat > "${BIN}/uname" <<EOS
#!/bin/sh
echo "\${STUB_OS:-Linux}"
EOS
cat > "${BIN}/ip" <<EOS
#!/bin/sh
case "\$*" in
    "route show default") echo "default via 192.168.1.1 dev eth0 proto dhcp metric 100" ;;
    "route show dev eth0 scope link proto kernel") echo "192.168.1.0/24 src 192.168.1.20" ;;
esac
EOS
# iptables: each chain is a file with one rule per line, top first.
cat > "${BIN}/iptables" <<EOS
#!/bin/bash
op=\$1; [ "\$op" = -n ] && exit 0
chain="${ST}/chain-\$2"; touch "\$chain"
case "\$op" in
    -S) cat "\$chain" ;;
    -C) shift 2; grep -qxF -- "\$*" "\$chain" ;;
    -I) shift 2; { echo "\$*"; cat "\$chain"; } > "\$chain.new"; mv "\$chain.new" "\$chain" ;;
    -D) shift 2; grep -vxF -- "\$*" "\$chain" > "\$chain.new"; mv "\$chain.new" "\$chain" ;;
esac
EOS
cat > "${BIN}/docker" <<EOS
#!/bin/bash
echo "docker \$*" >> "${ST}/docker.log"
case "\$1 \$2" in
    "network inspect")
        shift 2; fmt=""; [ "\$1" = -f ] && { fmt=\$2; shift 2; }
        [ -f "${ST}/net-\$1" ] || exit 1
        case "\$fmt" in *Driver*Subnet*|"") cat "${ST}/net-\$1" ;; *Driver*) echo "\$(cut -d' ' -f1 "${ST}/net-\$1")" ;; *Subnet*) cut -d' ' -f2 "${ST}/net-\$1" ;; esac ;;
    "network create")
        shift 2; drv=bridge; sub=""
        while [ \$# -gt 1 ]; do case "\$1" in -d) drv=\$2; shift 2 ;; --subnet) sub=\$2; shift 2 ;; *) shift ;; esac; done
        echo "\$drv \$sub" > "${ST}/net-\$1" ;;
    "network rm") rm -f "${ST}/net-\$3" ;;
    "run --rm") cat "${ST}/run-output" ;;
    "info "*) [ "\$2" = --format ] && echo "\${STUB_DOCKER_OS:-Debian}" ;;
esac
exit 0
EOS
chmod +x "${BIN}/id" "${BIN}/uname" "${BIN}/ip" "${BIN}/iptables" "${BIN}/docker"

PASS=0; FAIL=0; OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
mentions() { grep -qF -- "$1" <<<"${OUT}"; }
lacks() { ! mentions "$1"; }
chain_has() { grep -qxF -- "$2" "${ST}/chain-$1"; }   # CHAIN RULE
chain_count() { { cat "${ST}/chain-$1" 2>/dev/null || true; } | wc -l | tr -d ' '; }
logged() { grep -qF -- "$1" "${ST}/docker.log"; }

reset() { find "${ST}" -mindepth 1 -delete; printf 'nameserver 192.168.1.53\n' > "${WORK}/resolv.conf"; }
# net_sh ARGS... -- run network.sh with the stubs, the resolv.conf under test, and the Wi-Fi flag.
net_sh() {
    sed "s#/etc/resolv.conf#${WORK}/resolv.conf#; s#/sys/class/net/#${WORK}/sys/#" "${ROOT}/network.sh" > "${WORK}/n.sh"
    OUT=$(env -i PATH="${BIN}" HOME="${WORK}" STUB_UID="${STUB_UID:-0}" STUB_OS="${STUB_OS:-Linux}" STUB_DOCKER_OS="${STUB_DOCKER_OS:-Debian}" bash "${WORK}/n.sh" "$@" 2>&1); return $?
}

# --- bridge -------------------------------------------------------------------
reset
net_sh setup bridge --yes; rc=$?
check "bridge setup succeeds" test "${rc}" -eq 0
check "creates the network on the default subnet" logged "network create --subnet 172.30.0.0/24 claude-sandbox"
for r in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    check "drops traffic to ${r}" chain_has DOCKER-USER "-s 172.30.0.0/24 -d ${r} -j DROP"
done
check "lets DNS through to the resolver" chain_has DOCKER-USER "-s 172.30.0.0/24 -d 192.168.1.53 -p udp --dport 53 -j ACCEPT"
check "the DNS accept is evaluated before the drops" test "$(head -n 1 "${ST}/chain-DOCKER-USER")" = "-s 172.30.0.0/24 -d 192.168.1.53 -p udp --dport 53 -j ACCEPT"
check "traffic to the host is dropped (INPUT)" chain_has INPUT "-s 172.30.0.0/24 -j DROP"
check "replies to the host's own connections are accepted" chain_has INPUT "-s 172.30.0.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
check "the host rules end with the drop, accepts first" test "$(tail -n 1 "${ST}/chain-INPUT")" = "-s 172.30.0.0/24 -j DROP"
check "prints the setting to use" mentions 'export CS_DOCKER_FLAGS="--network claude-sandbox"'

net_sh setup bridge --yes; rc=$?
check "a second run succeeds" test "${rc}" -eq 0
check "...and adds no duplicate rule" test "$(chain_count DOCKER-USER)+$(chain_count INPUT)" = "4+3"

reset; printf 'nameserver 8.8.8.8\n' > "${WORK}/resolv.conf"
net_sh setup bridge --yes
check "a public resolver needs no accept rule" test "$(chain_count DOCKER-USER)+$(chain_count INPUT)" = "3+2"

reset; printf 'nameserver 127.0.0.53\n' > "${WORK}/resolv.conf"
net_sh setup bridge --yes
check "a loopback resolver is reported" mentions "local to the host"
check "...and no accept rule is made for it" test "$(chain_count DOCKER-USER)+$(chain_count INPUT)" = "3+2"

reset
STUB_UID=1000 net_sh setup bridge --yes; rc=$?
check "bridge setup refuses to run without root" test "${rc}" -ne 0
check "...and says so" mentions "as root"
check "...and creates nothing" test ! -e "${ST}/net-claude-sandbox"

reset
STUB_OS=Darwin net_sh setup bridge --yes; rc=$?
check "refuses on a host that is not Linux" test "${rc}" -ne 0
reset
STUB_DOCKER_OS="Docker Desktop" net_sh setup bridge --yes; rc=$?
check "refuses on Docker Desktop" test "${rc}" -ne 0

# --- remove -------------------------------------------------------------------
reset; net_sh setup bridge --yes
net_sh remove; rc=$?
check "remove succeeds" test "${rc}" -eq 0
check "remove deletes the rules" test "$(chain_count DOCKER-USER)+$(chain_count INPUT)" = "0+0"
check "remove deletes the network" test ! -e "${ST}/net-claude-sandbox"

# --- macvlan and ipvlan -------------------------------------------------------
reset
net_sh setup macvlan --yes; rc=$?
check "macvlan needs --ip-range" test "${rc}" -ne 0
check "...and says what it is for" mentions "your DHCP server does not hand out"

reset
net_sh setup macvlan --ip-range 10.9.9.0/28 --yes; rc=$?
check "an ip-range outside the LAN subnet is refused" test "${rc}" -ne 0

reset
net_sh setup macvlan --ip-range 192.168.1.192/28 --yes; rc=$?
check "macvlan setup succeeds" test "${rc}" -eq 0
check "macvlan is created with the detected interface, subnet and gateway" logged "network create -d macvlan --subnet 192.168.1.0/24 --gateway 192.168.1.1 --ip-range 192.168.1.192/28 -o parent=eth0 claude-sandbox"
check "macvlan makes no firewall rules" test "$(chain_count DOCKER-USER)+$(chain_count INPUT)" = "0+0"
reset
STUB_UID=1000 net_sh setup macvlan --ip-range 192.168.1.192/28 --yes; rc=$?
check "macvlan does not need root" test "${rc}" -eq 0

reset; mkdir -p "${WORK}/sys/eth0/wireless"
net_sh setup macvlan --ip-range 192.168.1.192/28 --yes; rc=$?
check "macvlan over Wi-Fi is refused" test "${rc}" -ne 0
check "...pointing at ipvlan" mentions "ipvlan"
net_sh setup ipvlan --ip-range 192.168.1.192/28 --yes; rc=$?
check "ipvlan works over Wi-Fi" test "${rc}" -eq 0
check "ipvlan is created in l2 mode" logged "network create -d ipvlan --subnet 192.168.1.0/24 --gateway 192.168.1.1 --ip-range 192.168.1.192/28 -o parent=eth0 -o ipvlan_mode=l2 claude-sandbox"
rm -rf "${WORK}/sys"

reset
net_sh setup ipvlan --ip-range 192.168.1.192/28 --mode l3 --parent eth1 --subnet 192.168.1.0/24 --gateway 192.168.1.254 --yes
check "explicit options override detection" logged "--gateway 192.168.1.254 --ip-range 192.168.1.192/28 -o parent=eth1 -o ipvlan_mode=l3"

reset
net_sh setup macvlan --ip-range 192.168.1.192/28 --name mynet --yes
check "--name picks the network name" test -e "${ST}/net-mynet"

net_sh setup bogus; rc=$?
check "an unknown network type is an error" test "${rc}" -ne 0

# --- check --------------------------------------------------------------------
reset; net_sh setup bridge --yes
printf 'lan=blocked\nhost=blocked\ndns=ok\ninternet=ok\n' > "${ST}/run-output"
net_sh check; rc=$?
check "check passes when the LAN is blocked and the internet works" test "${rc}" -eq 0
check "...reporting the LAN host as blocked" mentions "192.168.1.1 is blocked"
printf 'lan=blocked\nhost=22,5000\ndns=ok\ninternet=ok\n' > "${ST}/run-output"
net_sh check; rc=$?
check "check fails when the sandbox can open ports on the host" test "${rc}" -ne 0
check "...naming the ports" mentions "ports 22,5000 on the host"
printf 'lan=reachable\nhost=blocked\ndns=ok\ninternet=ok\n' > "${ST}/run-output"
net_sh check; rc=$?
check "check fails when a bridge can still reach the LAN" test "${rc}" -ne 0
check "...saying the rules are not in effect" mentions "not in effect"
printf 'lan=blocked\nhost=blocked\ndns=fail\ninternet=ok\n' > "${ST}/run-output"
net_sh check; rc=$?
check "check fails when DNS does not work" test "${rc}" -ne 0
reset; net_sh check; rc=$?
check "check without a network is an error" test "${rc}" -ne 0

echo; echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
