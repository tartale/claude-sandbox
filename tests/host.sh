#!/usr/bin/env bash
# Tests for the host scripts behind cs build and cs run, and the project detection they share.
# docker and the scripts they hand over to are stubs.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

BIN="${WORK}/bin"; H="${WORK}/host"; LOG="${WORK}/log"; PROJ="${WORK}/Some Project"
mkdir -p "${BIN}" "${H}" "${PROJ}"
for f in /usr/bin/* /bin/*; do
    case "${f##*/}" in docker) continue ;; esac
    ln -sf "$f" "${BIN}/${f##*/}" 2>/dev/null || true
done
cp "${ROOT}/host/lib.sh" "${ROOT}/host/run.sh" "${ROOT}/host/build.sh" "${H}/"
# The scripts run and build.sh hand over to: they record how they were called.
printf '#!/bin/bash\necho "claude-sandbox $* name=$CS_CONTAINER_NAME tag=$CS_IMAGE_TAG pwd=$PWD" >> "%s"\n' "${LOG}" > "${H}/claude-sandbox.sh"
printf '#!/bin/bash\necho "build-image $* plugins=$PLUGINS tag=$CS_IMAGE_TAG" >> "%s"\n' "${LOG}" > "${H}/build-image.sh"
chmod +x "${H}"/*.sh
# docker: "$RUNNING" lists containers that are running; rm and inspect are recorded.
cat > "${BIN}/docker" <<EOS
#!/bin/bash
echo "docker \$*" >> "${LOG}"
if [ "\$1" = inspect ]; then
    for r in \${RUNNING:-}; do [ "\$4" = "\$r" ] && { echo true; exit 0; }; done
    exit 1
fi
EOS
chmod +x "${BIN}/docker"

PASS=0; FAIL=0; OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
logged() { grep -qF -- "$1" "${LOG}"; }
not_logged() { ! logged "$1"; }
run() { : > "${LOG}"; OUT=$(env -i PATH="${BIN}" HOME="${WORK}" "$@" 2>&1); }   # ENV=... COMMAND...

# --- project detection ----------------------------------------------------------
project() { ( cd "$1" || exit; . "${H}/lib.sh"; cs_project_env; echo "${CS_PROJECT_DIR}|${CS_PROJECT_NAME}|${CS_PROJECT_TAG}" ); }
git -C "${PROJ}" init -q
mkdir -p "${PROJ}/.claude/sandbox"; : > "${PROJ}/.claude/sandbox/plugin.sh"
check "with no remote the project is its directory" test "$(project "${PROJ}")" = "${PROJ}|Some Project|some-project"
git -C "${PROJ}" remote add origin git@github.com:o/Demo_App.Next.git
check "the name comes from the origin remote, the tag from the name" test "$(project "${PROJ}")" = "${PROJ}|Demo_App.Next|demo_app.next"
mkdir -p "${PROJ}/sub/dir"
check "from a subdirectory the project is the git root" test "$(project "${PROJ}/sub/dir")" = "${PROJ}|Demo_App.Next|demo_app.next"
check "CS_PROJECT_DIR and CS_PROJECT_NAME win" test "$(cd "${WORK}" && CS_PROJECT_DIR=/x CS_PROJECT_NAME=Other bash -c '. "$1"; cs_project_env; echo "$CS_PROJECT_DIR $CS_PROJECT_TAG"' _ "${H}/lib.sh")" = "/x other"

# --- cs build -------------------------------------------------------------------------
run CS_PROJECT_DIR="${PROJ}" CS_PROJECT_NAME=Demo-App bash "${H}/build.sh" --no-push
check "build hands over to build-image.sh with its arguments" logged "build-image --no-push"
check "...the project's plugin.sh" logged "plugins=${PROJ}/.claude/sandbox/plugin.sh"
check "...and the project's image tag" logged "tag=demo-app"
run CS_PROJECT_DIR="${PROJ}" CS_PROJECT_NAME=Demo-App PLUGINS=go bash "${H}/build.sh"
check "PLUGINS overrides the project's plugin.sh" logged "plugins=go "
run CS_PROJECT_DIR="${WORK}" CS_PROJECT_NAME=Demo-App bash "${H}/build.sh"
check "with no plugin.sh and no PLUGINS the base image is built" logged "plugins= "
run CS_IMAGE_TAG=mine CS_PROJECT_DIR="${PROJ}" CS_PROJECT_NAME=Demo-App bash "${H}/build.sh"
check "CS_IMAGE_TAG overrides the default tag" logged "tag=mine"

# --- cs run ---------------------------------------------------------------------------
run CS_PROJECT_DIR="${PROJ}" CS_PROJECT_NAME=Demo-App bash "${H}/run.sh" --continue "two words"
check "run starts the launcher with --name and the claude arguments" logged "claude-sandbox --name Demo-App --continue two words"
check "...from the project directory" logged "pwd=${PROJ}"
check "...with the project's image tag" logged "tag=demo-app"
check "...in a container named after the project" logged "name=cs-demo-app "
check "...removing a stopped container of that name first" logged "docker rm cs-demo-app"
run RUNNING="cs-demo-app cs-demo-app-2" CS_PROJECT_DIR="${PROJ}" CS_PROJECT_NAME=Demo-App bash "${H}/run.sh"
check "a second sandbox gets the next free name" logged "name=cs-demo-app-3 "
run CS_CONTAINER_NAME=fixed RUNNING="fixed" CS_PROJECT_DIR="${PROJ}" CS_PROJECT_NAME=Demo-App bash "${H}/run.sh"
check "CS_CONTAINER_NAME is used as given" logged "name=fixed "
check "...without touching docker" not_logged "docker "

echo; echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
