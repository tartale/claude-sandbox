#!/usr/bin/env bash
# Network setup for the sandbox containers, run once per host (not per project).
#
#   network.sh setup bridge  [--subnet CIDR] [--resolver IP]
#   network.sh setup macvlan --ip-range CIDR [--parent IFACE] [--subnet CIDR] [--gateway IP]
#   network.sh setup ipvlan  --ip-range CIDR [--parent IFACE] [--subnet CIDR] [--gateway IP] [--mode l2|l3]
#   network.sh check  [LAN_HOST]
#   network.sh status
#   network.sh remove
#
# bridge  a docker network of its own, plus iptables rules that drop traffic from it to the private
#         ranges (your LAN) and to the host itself (ssh, the admin UI), while letting DNS reach your
#         resolver. Needs root and a Linux host.
# macvlan/ipvlan  the network gets its own LAN addresses, from --ip-range, so a router or
#         firewall can filter it by address. Use a range your DHCP server does not hand out.
#         macvlan does not work over Wi-Fi; ipvlan l2 does.
# Every option is detected from the host's default route when it can be; the result is shown
# before anything is created. Nothing here survives a reboot except the docker network itself:
# the iptables rules have to be applied again (run setup again; it only adds what is missing).
#
# Options: --name NAME (default claude-sandbox)   --yes (skip the confirmation)
set -euo pipefail

NAME=claude-sandbox
YES=false
SUBNET=""; RESOLVER=""; IP_RANGE=""; PARENT=""; GATEWAY=""; MODE=l2
BRIDGE_SUBNET=172.30.0.0/24
PRIVATE_RANGES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n%s\n' "$*"; }
ok() { echo "  ok    $*"; }
note() { echo "        $*"; }
warn() { echo "  warn  $*" >&2; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
valid_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
# in_cidr IP CIDR -- true when IP lies in CIDR.
in_cidr() {
    local bits=${2#*/} mask
    mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( $(ip2int "$1") & mask )) -eq $(( $(ip2int "${2%/*}") & mask )) ]
}
# net_of CIDR -- the network address of CIDR, as an integer.
net_of() { local bits=${1#*/}; echo $(( $(ip2int "${1%/*}") & ((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF) )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
# cidr_within INNER OUTER -- true when every address of INNER is in OUTER.
cidr_within() { [ "${1#*/}" -ge "${2#*/}" ] && in_cidr "${1%/*}" "$2"; }

need_root() { [ "$(id -u)" = 0 ] || die "run this as root (sudo): it changes firewall rules"; }
need_docker() {
    command -v docker >/dev/null || die "docker not found"
    docker info >/dev/null 2>&1 || die "cannot reach the docker daemon"
    case "$(uname -s)" in Linux) ;; *) die "this needs a Linux docker host; Docker Desktop has no host network to configure" ;; esac
    case "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)" in
        *"Docker Desktop"*) die "Docker Desktop runs in a VM and cannot be given LAN addresses or host firewall rules; use a Linux host or NAS" ;;
    esac
}
exists() { docker network inspect "$NAME" >/dev/null 2>&1; }
# existing_matches DRIVER SUBNET IP_RANGE -- an existing network of this name is only kept when it
# is the one asked for; a leftover of another type or range would otherwise be reported as done.
existing_matches() {
    local have want="$1|$2|$3"
    have=$(docker network inspect -f '{{.Driver}}|{{range .IPAM.Config}}{{.Subnet}}|{{.IPRange}}{{end}}' "$NAME")
    [ "$have" = "$want" ] && return 0
    warn "network $NAME already exists, as ${have//|/ } (wanted ${want//|/ })"
    die "run 'network.sh remove' first (it also removes the firewall rules), or pick another --name"
}
confirm() {
    [ "$YES" = true ] && return 0
    local a; read -r -p "  Create it? [Y/n] " a
    ! [[ "$a" =~ ^[Nn] ]]
}

# --- detection from the default route -----------------------------------------
detect_parent() { ip route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'; }
detect_gateway() { ip route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }'; }
detect_subnet() { ip route show dev "$1" scope link proto kernel 2>/dev/null | awk '{ print $1; exit }'; }
detect_resolver() { awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf 2>/dev/null; }

# --- bridge ----------------------------------------------------------------------
# DOCKER-USER rules run before docker's own, and INPUT rules see traffic to the host itself. Each
# ACCEPT is inserted after its DROP so it is evaluated first; -C makes every step safe to repeat.
bridge_rules() {   # SUBNET RESOLVER -- prints "CHAIN rule" lines, the last-evaluated first
    local r
    for r in $PRIVATE_RANGES; do echo "DOCKER-USER -s $1 -d $r -j DROP"; done
    [ -z "$2" ] || echo "DOCKER-USER -s $1 -d $2 -p udp --dport 53 -j ACCEPT"
    # Traffic to the host's own addresses (ssh, the admin UI) goes through INPUT, not
    # DOCKER-USER: drop what the sandbox starts there, but let replies and DNS through.
    echo "INPUT -s $1 -j DROP"
    [ -z "$2" ] || echo "INPUT -s $1 -d $2 -p udp --dport 53 -j ACCEPT"
    echo "INPUT -s $1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
}
rule_add() { read -r -a a <<<"$1"; iptables -C "${a[@]}" 2>/dev/null && { note "kept    iptables ${a[*]}"; return; }; iptables -I "${a[@]}"; ok "added   iptables ${a[*]}"; }
rule_del() { read -r -a a <<<"$1"; while iptables -C "${a[@]}" 2>/dev/null; do iptables -D "${a[@]}"; ok "removed iptables ${a[*]}"; done; }

setup_bridge() {
    need_root; need_docker
    command -v iptables >/dev/null || die "iptables not found"
    iptables -n -L DOCKER-USER >/dev/null 2>&1 || die "no DOCKER-USER chain: is docker running with iptables enabled?"
    local subnet=${SUBNET:-$BRIDGE_SUBNET} resolver=${RESOLVER:-$(detect_resolver)} private=false r
    valid_cidr "$subnet" || die "not a CIDR: $subnet"
    say "Bridge network $NAME"
    note "subnet    $subnet"
    if [ -z "$resolver" ]; then
        warn "no resolver found; pass --resolver IP. Without a rule for it the sandbox cannot resolve names."
    elif ! valid_ip "$resolver"; then
        die "not an IP address: $resolver"
    elif [[ "$resolver" == 127.* ]]; then
        warn "resolver $resolver is local to the host; pass --resolver IP of one the sandbox can reach"
        resolver=""
    else
        for r in $PRIVATE_RANGES; do in_cidr "$resolver" "$r" && private=true; done
        if [ "$private" = true ]; then note "resolver  $resolver (reachable: allowed through)"
        else note "resolver  $resolver (public: not blocked, no rule needed)"; resolver=""; fi
    fi
    note "blocks     $PRIVATE_RANGES"
    if exists; then existing_matches bridge "$subnet" ""; ok "network $NAME already exists"
    else
        confirm || die "stopped"
        docker network create --subnet "$subnet" "$NAME" >/dev/null
        ok "created network $NAME"
    fi
    while IFS= read -r line; do rule_add "$line"; done < <(bridge_rules "$subnet" "$resolver")
    note "INPUT rules also stop the sandbox opening connections to the host itself (ssh, admin UI). On a NAS whose"
    note "firewall rewrites INPUT, check they are still first after changing its settings: network.sh check."
    next_steps
}

# --- macvlan / ipvlan ------------------------------------------------------------
setup_lan() {   # driver
    need_docker
    command -v ip >/dev/null || die "ip (iproute2) not found"
    local driver=$1 parent=${PARENT:-$(detect_parent)} subnet gateway
    [ -n "$parent" ] || die "could not find the default network interface; pass --parent IFACE"
    [ -n "$IP_RANGE" ] || die "--ip-range CIDR is required: a slice of your LAN that your DHCP server does not hand out, for example 192.168.1.192/28"
    valid_cidr "$IP_RANGE" || die "not a CIDR: $IP_RANGE"
    subnet=${SUBNET:-$(detect_subnet "$parent")}; gateway=${GATEWAY:-$(detect_gateway)}
    { [ -n "$subnet" ] && valid_cidr "$subnet"; } || die "could not work out the LAN subnet; pass --subnet CIDR"
    valid_ip "$gateway" || die "could not work out the gateway; pass --gateway IP"
    cidr_within "$IP_RANGE" "$subnet" || die "--ip-range $IP_RANGE is not inside the subnet $subnet"
    if [ "${IP_RANGE#*/}" -le "${subnet#*/}" ] || [ "$(net_of "$IP_RANGE")" != "$(ip2int "${IP_RANGE%/*}")" ]; then
        local bits=28 slice
        slice="$(int2ip "$(net_of "${IP_RANGE%/*}/$bits")")/$bits"
        die "--ip-range $IP_RANGE is not a slice of $subnet: it covers the whole LAN or has host bits set. Give a small block your DHCP server does not hand out, for example $slice"
    fi
    if [ "$driver" = macvlan ] && [ -d "/sys/class/net/$parent/wireless" ]; then
        die "$parent is a Wi-Fi interface and macvlan does not work over it; use: network.sh setup ipvlan ..."
    fi
    say "$driver network $NAME"
    note "parent     $parent"; note "subnet     $subnet"; note "gateway    $gateway"; note "ip range   $IP_RANGE"
    [ "$driver" = ipvlan ] && note "mode       $MODE"
    if exists; then existing_matches "$driver" "$subnet" "$IP_RANGE"; ok "network $NAME already exists"
    else
        confirm || die "stopped"
        local args=(-d "$driver" --subnet "$subnet" --gateway "$gateway" --ip-range "$IP_RANGE" -o "parent=$parent")
        [ "$driver" = ipvlan ] && args+=(-o "ipvlan_mode=$MODE")
        docker network create "${args[@]}" "$NAME" >/dev/null
        ok "created network $NAME"
    fi
    note "Containers get addresses from $IP_RANGE. Write your router or firewall rules against that range"
    note "(allow github.com, api.github.com, api.anthropic.com and your package registries; block the rest)."
    note "The host cannot reach these containers by default (macvlan and ipvlan isolate them from their parent)."
    next_steps
}

next_steps() {
    say "Use it"
    note "Add this to .envrc-cs in each project, then restart the sandbox:"
    echo
    echo "export CS_DOCKER_FLAGS=\"--network $NAME\""
    echo
    note "Verify with: network.sh check"
}

# --- check -----------------------------------------------------------------------
check() {   # [LAN_HOST]
    need_docker
    exists || die "no network named $NAME; run setup first"
    local driver lan=${1:-$(detect_gateway)} out
    [ -n "$lan" ] || die "pass a LAN host to test, for example your router: network.sh check 192.168.1.1"
    driver=$(docker network inspect -f '{{.Driver}}' "$NAME")
    say "Checking $NAME ($driver) from a throwaway container"
    out=$(docker run --rm --network "$NAME" alpine sh -c '
        if ping -c 1 -W 2 "$1" >/dev/null 2>&1; then echo lan=reachable; else echo lan=blocked; fi
        gw=$(ip route | awk "/default/ { print \$3; exit }"); open=""
        for p in 22 80 443 5000 5001; do nc -w 2 "$gw" "$p" </dev/null >/dev/null 2>&1 && open="$open,$p"; done
        if [ -n "$open" ]; then echo "host=${open#,}"; else echo host=blocked; fi
        if nslookup github.com >/dev/null 2>&1; then echo dns=ok; else echo dns=fail; fi
        if wget -q -T 5 -O /dev/null https://github.com 2>/dev/null; then echo internet=ok; else echo internet=fail; fi
    ' sh "$lan" 2>&1) || die "the test container did not run: $out"
    local lanres hostres dnsres netres bad=false
    hostres=$(sed -n 's/^host=//p' <<<"$out")
    lanres=$(sed -n 's/^lan=//p' <<<"$out"); dnsres=$(sed -n 's/^dns=//p' <<<"$out"); netres=$(sed -n 's/^internet=//p' <<<"$out")
    if [ "$driver" = bridge ]; then
        if [ "$lanres" = blocked ]; then ok "LAN host $lan is blocked"; else warn "LAN host $lan is reachable: the DROP rules are not in effect"; bad=true; fi
        if [ "$hostres" = blocked ]; then ok "the host itself is blocked (ssh, web, DSM ports)"
        else warn "the sandbox can open ports $hostres on the host: the INPUT rules are not in effect"; bad=true; fi
    else
        note "LAN host $lan: $lanres (the router decides for $driver; this is only informational)"
    fi
    if [ "$dnsres" = ok ]; then ok "DNS works"; else warn "DNS does not work"; bad=true; fi
    if [ "$netres" = ok ]; then ok "the internet is reachable"; else warn "the internet is not reachable"; bad=true; fi
    [ "$bad" = false ]
}

status() {
    need_docker
    if exists; then
        docker network inspect -f '  network {{.Name}}: driver {{.Driver}}, {{range .IPAM.Config}}subnet {{.Subnet}} gateway {{.Gateway}} {{end}}' "$NAME"
    else
        echo "  no network named $NAME"
    fi
    if command -v iptables >/dev/null && [ "$(id -u)" = 0 ]; then
        local chain
        for chain in DOCKER-USER INPUT; do
            echo "  $chain rules:"
            iptables -S "$chain" 2>/dev/null | grep -- '-s ' | sed 's/^/    /' || echo "    none"
        done
    fi
}

remove() {
    need_docker
    local subnet=""
    if exists; then subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NAME"); fi
    if command -v iptables >/dev/null && [ "$(id -u)" = 0 ] && [ -n "$subnet" ]; then
        local resolver line
        resolver=$(detect_resolver)
        while IFS= read -r line; do rule_del "$line"; done < <(bridge_rules "$subnet" "${RESOLVER:-$resolver}")
    elif [ -n "$subnet" ]; then
        note "Not root: any iptables rules for $subnet are left in place."
    fi
    if exists; then docker network rm "$NAME" >/dev/null && ok "removed network $NAME"; else note "no network named $NAME"; fi
}

# --- arguments -------------------------------------------------------------------
[ "$#" -gt 0 ] || { usage; exit 2; }
CMD=$1; shift
KIND=""
if [ "$CMD" = setup ]; then
    [ "$#" -gt 0 ] || die "usage: network.sh setup bridge|macvlan|ipvlan"
    KIND=$1; shift
fi
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) NAME=${2:?--name needs a value}; shift 2 ;;
        --subnet) SUBNET=${2:?--subnet needs a value}; shift 2 ;;
        --resolver) RESOLVER=${2:?--resolver needs a value}; shift 2 ;;
        --ip-range) IP_RANGE=${2:?--ip-range needs a value}; shift 2 ;;
        --parent) PARENT=${2:?--parent needs a value}; shift 2 ;;
        --gateway) GATEWAY=${2:?--gateway needs a value}; shift 2 ;;
        --mode) MODE=${2:?--mode needs a value}; shift 2 ;;
        --yes) YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
case "$MODE" in l2|l3) ;; *) die "--mode is l2 or l3" ;; esac

case "$CMD" in
    setup)
        case "$KIND" in
            bridge) setup_bridge ;;
            macvlan|ipvlan) setup_lan "$KIND" ;;
            *) die "unknown network type: $KIND (bridge, macvlan or ipvlan)" ;;
        esac ;;
    check) check "${POSITIONAL[0]:-}" ;;
    status) status ;;
    remove) remove ;;
    *) usage; exit 2 ;;
esac
