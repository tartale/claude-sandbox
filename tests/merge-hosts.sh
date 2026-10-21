#!/usr/bin/env bash
# Tests for merge-hosts.sh: the host's hosts entries added to the ones docker wrote.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

PASS=0
FAIL=0
OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
has() { grep -qxF -- "$1" "${TARGET}"; }
absent() { ! has "$1"; }

TARGET="${WORK}/hosts"
HOST_COPY="${WORK}/host-hosts"

cat > "${TARGET}" <<'HOSTS'
127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
172.17.0.1	gw
10.1.2.3	db.local
172.17.0.2	abc123
HOSTS
cat > "${HOST_COPY}" <<'HOSTS'
127.0.0.1	localhost
192.168.1.5	nas.lan
10.9.9.9	db.local
HOSTS

OUT=$(bash "${ROOT}/merge-hosts.sh" "${HOST_COPY}" "${TARGET}" 2>&1); rc=$?
check "merging succeeds" test "${rc}" -eq 0
check "docker's host-gateway entry is kept" has "172.17.0.1	gw"
check "docker's --add-host entry is kept" has "10.1.2.3	db.local"
check "docker's container entry is kept" has "172.17.0.2	abc123"
check "the host's entries are added" has "192.168.1.5	nas.lan"
check "an entry already there is not repeated" test "$(grep -cxF '127.0.0.1	localhost' "${TARGET}")" -eq 1
check "IPv6 localhost is dropped" absent "::1	localhost ip6-localhost ip6-loopback"
check "docker's entries come before the host's" test "$(grep -n 'db.local' "${TARGET}" | head -1 | cut -d: -f2)" = "10.1.2.3	db.local"

ino=$(stat -c %i "${TARGET}")
bash "${ROOT}/merge-hosts.sh" "${HOST_COPY}" "${TARGET}"
check "a second run changes nothing" test "$(grep -c . "${TARGET}")" -eq 6
check "the target is rewritten in place" test "$(stat -c %i "${TARGET}")" = "${ino}"

: > "${HOST_COPY}"
OUT=$(bash "${ROOT}/merge-hosts.sh" "${HOST_COPY}" "${TARGET}" 2>&1); rc=$?
check "an empty host copy is fine" test "${rc}" -eq 0

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
