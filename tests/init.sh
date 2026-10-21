#!/usr/bin/env bash
# Tests for init.sh: the stubs it generates and how it treats files you edited.
# curl, gh and docker are absent from the test PATH and envsubst is a stand-in, so
# nothing here touches the network; every question about a token, registry login or
# ruleset is answered "n".
# shellcheck disable=SC2016  # literal $ in fixtures
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

BIN="${WORK}/bin"
mkdir -p "${BIN}" "${WORK}/home" "${WORK}/proj"
for f in /usr/bin/* /bin/*; do
    case "${f##*/}" in envsubst|gh|curl|docker|direnv|open|xdg-open) continue ;; esac
    ln -sf "$f" "${BIN}/${f##*/}" 2>/dev/null || true
done
printf '#!/bin/sh\nexit 0\n' > "${BIN}/curl"
printf '#!/bin/sh\ncat\n' > "${BIN}/envsubst"
chmod +x "${BIN}/curl" "${BIN}/envsubst"

# A copy of init.sh whose templates differ from the real ones, to stand in for
# "the template changed since the last run".
sed 's|^set -euo pipefail$|set -euo pipefail\n# new header line|' "${ROOT}/init.sh" > "${WORK}/init-changed.sh"
sed 's|^set -euo pipefail$|set -euo pipefail\n# conflicting header|' "${ROOT}/init.sh" > "${WORK}/init-conflict.sh"

PASS=0
FAIL=0
OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
mentions() { grep -qF -- "$1" <<<"${OUT}"; }
lacks() { ! mentions "$1"; }

STUBS="build.sh run.sh start.sh restart.sh sync.sh plugin.sh"
SB="${WORK}/proj/.claude/sandbox"

new_project() {
    find "${WORK}/proj" -mindepth 1 -delete
    find "${WORK}/home" -mindepth 1 -delete
    git -C "${WORK}/proj" init -q
    git -C "${WORK}/proj" remote add origin git@github.com:o/Demo-App.git
}

# run_init INPUT [SCRIPT] -- run init.sh in the scratch project on a pty, feeding
# INPUT (printf format) as the answers. Output lands in $OUT; init's exit status is returned.
run_init() {
    local rc
    OUT=$(cd "${WORK}/proj" && printf "$1" | env -i PATH="${BIN}" HOME="${WORK}/home" NO_COLOR=1 \
        script -qec "bash ${2:-${ROOT}/init.sh}" /dev/null 2>&1 | tr -d '\r')
    rc=${PIPESTATUS[0]}
    return "${rc}"
}
NO3='n\nn\nn\n'   # token, registry login, ruleset

has_file() { [ -f "$1" ]; }
mode_is() { [ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" = "$2" ]; }
backups() { find "${SB}" -name "$1.bak.*" | wc -l | tr -d ' '; }
contains() { grep -qF -- "$2" "$1"; }
absent() { ! contains "$@"; }

# --- a fresh project --------------------------------------------------------
new_project
run_init "${NO3}"; rc=$?
check "a fresh project runs to the end" test "${rc}" -eq 0
for s in ${STUBS}; do check "creates ${s}" has_file "${SB}/${s}"; done
for s in build.sh run.sh start.sh restart.sh sync.sh; do check "${s} is executable" mode_is "${SB}/${s}" 755; done
check "plugin.sh is not executable" mode_is "${SB}/plugin.sh" 644
check "stubs use the repo name as the image tag" contains "${SB}/build.sh" 'demo-app'
check "records the stub hashes" has_file "${SB}/.init-hashes"
for s in ${STUBS}; do check "keeps a copy of the ${s} template" has_file "${SB}/.init-base/${s}"; done

# plugin.sh lists every built-in plugin, commented out
builtin=$(find "${ROOT}/plugins/languages" "${ROOT}/plugins/tools" -name '*.sh' | wc -l | tr -d ' ')
listed=$(grep -c '^# "${PLUGINS_DIR}/' "${SB}/plugin.sh")
check "plugin.sh lists all ${builtin} built-in plugins" test "${listed}" -eq "${builtin}"
for p in "${ROOT}"/plugins/languages/*.sh "${ROOT}"/plugins/tools/*.sh; do
    rel=${p#"${ROOT}"/plugins/}
    check "plugin.sh lists ${rel}" contains "${SB}/plugin.sh" "${rel}"
done

# --- running again changes nothing ------------------------------------------
run_init "${NO3}"; rc=$?
check "a second run succeeds" test "${rc}" -eq 0
check "a second run finds the stubs up to date" mentions "up to date ${SB##"${WORK}"/proj/}/build.sh"
check "a second run asks nothing about stubs" lacks "looks edited"
check "a second run makes no backups" test "$(backups plugin.sh)" -eq 0

# --- an unedited stub follows the template ----------------------------------
run_init "${NO3}" "${WORK}/init-changed.sh"
check "an unedited stub is updated without a question" lacks "looks edited"
check "the updated stub has the new template text" contains "${SB}/build.sh" '# new header line'
check "an updated stub is backed up first" test "$(backups build.sh)" -eq 1

# --- an edited stub ---------------------------------------------------------
# A fresh project whose plugin.sh carries an edit. Answering a prompt records the
# new template, so each scenario starts from here.
edited_project() {
    new_project; run_init "${NO3}" >/dev/null
    echo "apt-get install -y mypkg" >> "${SB}/plugin.sh"
}

edited_project
run_init "${NO3}"
check "an edited stub with an unchanged template is left alone" contains "${SB}/plugin.sh" 'mypkg'
check "...without a question" lacks "looks edited"
check "...reported as kept" mentions "kept"

edited_project
run_init "n\n${NO3}" "${WORK}/init-changed.sh"
check "a changed template asks about an edited stub" mentions "looks edited"
check "the first prompt makes the diff the default" mentions "/D]"
check "n keeps the edited stub" contains "${SB}/plugin.sh" 'mypkg'
check "n makes no backup" test "$(backups plugin.sh)" -eq 0

edited_project
run_init "\n\n${NO3}" "${WORK}/init-changed.sh"
check "Enter shows the diff" mentions '+# new header line'
check "after the diff the default is no" mentions "[y/N/m/d]"
check "...and Enter then keeps the stub" contains "${SB}/plugin.sh" 'mypkg'

edited_project
run_init "y\n${NO3}" "${WORK}/init-changed.sh"
check "y replaces the stub" contains "${SB}/plugin.sh" '# new header line'
check "...dropping the edit" absent "${SB}/plugin.sh" 'mypkg'
check "y backs the edited stub up" test "$(backups plugin.sh)" -eq 1
check "the backup holds the edit" contains "$(find "${SB}" -name 'plugin.sh.bak.*' | head -n 1)" 'mypkg'
check "backups are git-excluded" git -C "${WORK}/proj" check-ignore -q "${SB}/plugin.sh.bak.1"

# --- merging ----------------------------------------------------------------
edited_project
run_init "m\n${NO3}" "${WORK}/init-changed.sh"
check "m is offered when the previous template is on hand" mentions "[y/n/m/D]"
check "m keeps your edit" contains "${SB}/plugin.sh" 'mypkg'
check "m brings in the template change" contains "${SB}/plugin.sh" '# new header line'
check "m leaves no conflict markers" absent "${SB}/plugin.sh" '<<<<<<<'
check "m backs the edited stub up" test "$(backups plugin.sh)" -eq 1

new_project; run_init "${NO3}" >/dev/null
sed -i.orig 's|^set -euo pipefail$|set -euo pipefail\n# my own header|' "${SB}/plugin.sh"
run_init "m\n${NO3}" "${WORK}/init-conflict.sh"
check "overlapping edits leave conflict markers" contains "${SB}/plugin.sh" '<<<<<<<'
check "...and a warning" mentions "with conflicts"

# without the kept template there is nothing to merge against
edited_project
find "${SB}/.init-base" -mindepth 1 -delete
run_init "n\n${NO3}" "${WORK}/init-changed.sh"
check "m is not offered without the previous template" lacks "m/D"

# --- user-scope settings in .env ----------------------------------------------
new_project
run_init "${NO3}"
ENVF="${WORK}/proj/.env"
check "adds the user-config repo, commented out, pre-filled from the owner" contains "${ENVF}" '# CS_USER_CONFIG_REPO=o/claude-user'
check "adds the user-config token, commented out and empty" contains "${ENVF}" '# CS_USER_CONFIG_TOKEN='
check "puts a comment above each" test "$(grep -c '^# [A-Z].*\.$' "${ENVF}")" -eq 2
check ".env is mode 600" mode_is "${ENVF}" 600
check ".env is git-excluded" contains "${WORK}/proj/.git/info/exclude" '.env'
printf 'CS_USER_CONFIG_REPO=me/mine\n' > "${ENVF}"
run_init "${NO3}"
check "an existing repo setting is kept" contains "${ENVF}" 'CS_USER_CONFIG_REPO=me/mine'
check "...and not repeated" test "$(grep -cE '^#? ?CS_USER_CONFIG_REPO=' "${ENVF}")" -eq 1
check "...while the missing token is added" contains "${ENVF}" '# CS_USER_CONFIG_TOKEN='

# --- restart.sh: build, stop, start with the old arguments ------------------
new_project
run_init "${NO3}"
RS="${WORK}/restart"
mkdir -p "${RS}/.claude/sandbox" "${RS}/bin"
cp "${SB}/restart.sh" "${RS}/.claude/sandbox/restart.sh"
printf '#!/bin/sh\necho "build" >> "%s/log"\n' "${RS}" > "${RS}/.claude/sandbox/build.sh"
printf '#!/bin/sh\necho "start $*" >> "%s/log"\n' "${RS}" > "${RS}/.claude/sandbox/start.sh"
printf '#!/bin/sh\ncase "$1" in\n  inspect) printf "%%s\\n" --name demo-app --continue "two words" ;;\n  stop) echo "stop $2" >> "%s/log" ;;\nesac\n' "${RS}" > "${RS}/bin/docker"
chmod +x "${RS}"/.claude/sandbox/*.sh "${RS}/bin/docker"
restart() { OUT=$(env -i PATH="${RS}/bin:${BIN}" bash "${RS}/.claude/sandbox/restart.sh" "$@" 2>&1); }
: > "${RS}/log"; restart
check "restart builds, stops, then starts" test "$(tr '\n' '|' < "${RS}/log")" = "build|stop cs-demo-app|start --continue two words|"
: > "${RS}/log"; restart --resume
check "explicit arguments replace the old ones" contains "${RS}/log" 'start --resume'

# --- --yes and --no ----------------------------------------------------------
edited_project
run_init "" "${WORK}/init-changed.sh --yes"; rc=$?
check "--yes finishes without being asked anything" test "${rc}" -eq 0
check "--yes replaces an edited stub whose template changed" contains "${SB}/plugin.sh" '# new header line'
check "...after a backup" test "$(backups plugin.sh)" -eq 1
check "--yes skips the token, which needs a pasted secret" lacks "Paste the token"
check "--yes does not touch the ruleset without gh" lacks "ruleset created"

edited_project
run_init "" "${WORK}/init-changed.sh --no"; rc=$?
check "--no finishes without being asked anything" test "${rc}" -eq 0
check "--no keeps an edited stub" contains "${SB}/plugin.sh" 'mypkg'
check "...and makes no backup" test "$(backups plugin.sh)" -eq 0

new_project
OUT=$(bash "${ROOT}/init.sh" --yes --no 2>&1); rc=$?
check "--yes with --no is an error" test "${rc}" -eq 2

# --- start.sh: restart policy ---------------------------------------------------
new_project
run_init "${NO3}"
SS="${WORK}/start"
mkdir -p "${SS}/.claude/sandbox" "${SS}/bin"
cp "${SB}/start.sh" "${SS}/.claude/sandbox/start.sh"
printf '#!/bin/sh\necho "echo \\"\\$CS_DOCKER_FLAGS\\" > %s/flags"\n' "${SS}" > "${SS}/bin/curl"
printf '#!/bin/sh\nexit 1\n' > "${SS}/bin/docker"
chmod +x "${SS}/bin/curl" "${SS}/bin/docker"
start() { OUT=$(env -i PATH="${SS}/bin:${BIN}" "$@" bash "${SS}/.claude/sandbox/start.sh" 2>&1); }
start
check "start.sh runs the container detached with --restart=unless-stopped" contains "${SS}/flags" '-d -t --restart=unless-stopped'
start CS_DOCKER_FLAGS="--restart=no"
check "a --restart in CS_DOCKER_FLAGS comes after it, so it wins" contains "${SS}/flags" '--restart=unless-stopped --restart=no'

# --- prerequisites ----------------------------------------------------------
new_project
rm -f "${BIN}/envsubst"
run_init "${NO3}"; rc=$?
check "a missing envsubst stops init" test "${rc}" -ne 0
check "...before asking anything" lacks "Create and store"
check "...and says how to install it" mentions "gettext-base"
check "...creating no stubs" test ! -e "${SB}/build.sh"
printf '#!/bin/sh\ncat\n' > "${BIN}/envsubst"; chmod +x "${BIN}/envsubst"

# --- usage ------------------------------------------------------------------
OUT=$(bash "${ROOT}/init.sh" --help 2>&1); rc=$?
check "--help exits 0" test "${rc}" -eq 0
OUT=$(bash "${ROOT}/init.sh" --bogus 2>&1); rc=$?
check "an unknown option is an error" test "${rc}" -eq 2

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
