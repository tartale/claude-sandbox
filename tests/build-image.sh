#!/usr/bin/env bash
# Tests for build-image.sh: which docker build arguments and secrets it passes. curl, docker
# and npm are stubs, so nothing touches the network or a docker daemon.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

BIN="${WORK}/bin"
LOG="${WORK}/docker.log"
mkdir -p "${BIN}" "${WORK}/ctx"
for f in /usr/bin/* /bin/*; do
    case "${f##*/}" in curl|docker|npm) continue ;; esac
    ln -sf "$f" "${BIN}/${f##*/}" 2>/dev/null || true
done
echo FROM scratch > "${WORK}/ctx/Dockerfile"
tar -czf "${WORK}/ctx.tgz" -C "${WORK}" ctx
printf '#!/bin/sh\ncat "%s"\n' "${WORK}/ctx.tgz" > "${BIN}/curl"
printf '#!/bin/sh\necho "npm $*" >> "%s"; echo 9.9.9\n' "${LOG}" > "${BIN}/npm"
# docker build: record the arguments and, for a --secret, the contents of its file.
cat > "${BIN}/docker" <<EOS
#!/bin/bash
echo "docker \$*" >> "${LOG}"
while [ \$# -gt 0 ]; do
    if [ "\$1" = --secret ]; then src=\${2#*src=}; echo "secret-content: \$(cat "\$src")" >> "${LOG}"; fi
    shift
done
EOS
chmod +x "${BIN}/curl" "${BIN}/npm" "${BIN}/docker"

PASS=0
FAIL=0
OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
logged() { grep -qF -- "$1" "${LOG}"; }
not_logged() { ! logged "$1"; }

build() { : > "${LOG}"; OUT=$(env -i PATH="${BIN}" HOME="${WORK}" "$@" bash "${ROOT}/build-image.sh" 2>&1); OUT+=$'\n'$(cat "${LOG}"); }
# build_args ARGS... -- run build-image.sh with command-line arguments.
build_args() { : > "${LOG}"; OUT=$(env -i PATH="${BIN}" HOME="${WORK}" bash "${ROOT}/build-image.sh" "$@" 2>&1); OUT+=$'\n'$(cat "${LOG}"); }

build
check "defaults to the public npm registry" logged "--build-arg NPM_REGISTRY=https://registry.npmjs.org/"
check "looks the Claude Code version up in that registry" logged "npm view --registry https://registry.npmjs.org/ @anthropic-ai/claude-code version"
check "mounts an empty npmrc secret when none is set" logged "secret-content: "

printf '//reg.example.com/:_authToken=abc\n' > "${WORK}/npmrc"
build CS_NPM_REGISTRY=https://reg.example.com/ CS_NPMRC="${WORK}/npmrc"
check "passes the chosen registry to the build" logged "--build-arg NPM_REGISTRY=https://reg.example.com/"
check "looks the version up in the chosen registry" logged "npm view --registry https://reg.example.com/"
check "mounts the npmrc as a secret" logged "secret-content: //reg.example.com/:_authToken=abc"
check "the credentials are not on the docker command line" test "$(grep '^docker build' "${LOG}" | grep -c abc)" -eq 0

build
check "pushes by default" logged "docker push"
build_args --no-push
check "--no-push builds" logged "docker build"
check "...and does not push" not_logged "docker push"
check "...and says it did not" grep -qF "not pushed" <<<"${OUT}"
build_args --bogus
check "an unknown option is an error" grep -qF "usage: build-image.sh" <<<"${OUT}"

build CS_NPMRC="${WORK}/missing"
check "a missing CS_NPMRC is an error" grep -qF "CS_NPMRC is not a file" <<<"${OUT}"
check "...and nothing is built" not_logged "docker build"

echo; echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
