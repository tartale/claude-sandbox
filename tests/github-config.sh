#!/usr/bin/env bash
# Tests for github-config.sh: the git config and gh environment the entrypoint sets up for
# github.com, Enterprise Server and Enterprise Cloud hosts.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

PASS=0; FAIL=0; OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
contains() { grep -qF -- "$2" "$1"; }
absent() { ! contains "$@"; }

# shellcheck source=../github-config.sh
. "${ROOT}/container/github-config.sh"
CFG="${WORK}/gitconfig"; HELPER="${WORK}/helper"

write_github_gitconfig github.com tok "${CFG}" "${HELPER}"
check "github.com: ssh remotes go over https" contains "${CFG}" 'insteadOf = git@github.com:'
check "github.com: the token is offered for github.com only" contains "${CFG}" '[credential "https://github.com"]'
check "the credential helper hands out the token" contains "${HELPER}" 'password=tok'
check "the helper is private to its owner" test "$(stat -c %a "${HELPER}")" = 700
check "branch tracking stays off" contains "${CFG}" 'autoSetupMerge = false'

rm -f "${HELPER}"
write_github_gitconfig ghe.corp.example tok "${CFG}" "${HELPER}"
check "Enterprise Server: ssh remotes of that host go over https" contains "${CFG}" '[url "https://ghe.corp.example/"]'
check "...for its own scp-style address" contains "${CFG}" 'insteadOf = git@ghe.corp.example:'
check "...with the token offered to that host" contains "${CFG}" '[credential "https://ghe.corp.example"]'
check "...and not to github.com" absent "${CFG}" 'github.com'

rm -f "${HELPER}"
write_github_gitconfig tenant.ghe.com "" "${CFG}" "${HELPER}"
check "without a token there is no credential section" absent "${CFG}" 'credential'
check "...and no helper script" test ! -e "${HELPER}"

gh_env() { ( unset GH_HOST GH_TOKEN GH_ENTERPRISE_TOKEN; export_gh_env "$1" "tok"; echo "GH_TOKEN=${GH_TOKEN-} GH_HOST=${GH_HOST-} GH_ENTERPRISE_TOKEN=${GH_ENTERPRISE_TOKEN-}" ); }
OUT=$(gh_env github.com)
check "github.com: gh gets GH_TOKEN and no host override" test "${OUT}" = "GH_TOKEN=tok GH_HOST= GH_ENTERPRISE_TOKEN="
OUT=$(gh_env ghe.corp.example)
check "Enterprise Server: gh gets the host and both token variables" test "${OUT}" = "GH_TOKEN=tok GH_HOST=ghe.corp.example GH_ENTERPRISE_TOKEN=tok"

echo; echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
