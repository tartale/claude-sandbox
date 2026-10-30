#!/usr/bin/env bash
# Tests for the cs command: help, dispatch to the host scripts, fetching its tree when it is
# run from curl, and the development commands. The tree cs dispatches into is a fake one whose
# scripts echo their arguments; docker, curl and npm are stubs.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

BIN="${WORK}/bin"; LOG="${WORK}/log"; TREE="${WORK}/tree"
mkdir -p "${BIN}" "${TREE}/host" "${TREE}/plugins" "${TREE}/tests"
for f in /usr/bin/* /bin/*; do
    case "${f##*/}" in curl|docker|npm) continue ;; esac
    ln -sf "$f" "${BIN}/${f##*/}" 2>/dev/null || true
done
cp "${ROOT}/cs" "${TREE}/cs"
for c in init build run start restart sync network tag-images; do
    printf '#!/bin/bash\necho "%s $* root=$CS_ROOT" >> "%s"\n' "${c}" "${LOG}" > "${TREE}/host/${c}.sh"
done
printf '#!/bin/bash\necho "stage $*" >> "%s"\n' "${LOG}" > "${TREE}/plugins/stage.sh"
printf '#!/bin/bash\necho "test-one" >> "%s"\n' "${LOG}" > "${TREE}/tests/one.sh"
printf '#!/bin/bash\necho "test-two" >> "%s"\n' "${LOG}" > "${TREE}/tests/two.sh"
chmod +x "${TREE}"/host/*.sh "${TREE}"/plugins/stage.sh
printf '#!/bin/sh\necho "docker $*" >> "%s"\nexit 1\n' "${LOG}" > "${BIN}/docker"
printf '#!/bin/sh\necho 9.9.9\n' > "${BIN}/npm"
# curl: record the URL; serve the fake tree as a tarball.
tar -czf "${WORK}/tree.tgz" -C "${WORK}" --transform 's#^tree#repo-abc123#' tree
cat > "${BIN}/curl" <<EOS
#!/bin/sh
for a; do u=\$a; done
echo "curl \$u" >> "${LOG}"
cat "${WORK}/tree.tgz"
EOS
chmod +x "${BIN}/docker" "${BIN}/npm" "${BIN}/curl"

PASS=0; FAIL=0; OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
mentions() { grep -qF -- "$1" <<<"${OUT}"; }
lacks() { ! mentions "$1"; }
logged() { grep -qF -- "$1" "${LOG}"; }
not_logged() { ! logged "$1"; }
cs() { : > "${LOG}"; OUT=$(cd "${WORK}" && env -i PATH="${BIN}" HOME="${WORK}" "$@" 2>&1); }

# --- help ---------------------------------------------------------------------
cs "${TREE}/cs"; rc=$?
check "cs with no arguments prints the usage" mentions "Usage: cs [OPTIONS] COMMAND [ARGS]..."
cs "${TREE}/cs" --help
COMMANDS="init build run start restart sync network test image push pull all tags clean stage-plugins"
for c in ${COMMANDS}; do
    check "cs --help lists ${c}" mentions "  ${c}"
done
check "cs --help groups the commands" mentions "Development commands:"
for c in ${COMMANDS}; do
    cs "${TREE}/cs" "${c}" --help
    check "cs ${c} --help shows its usage" mentions "Usage: cs ${c}"
    check "...and runs nothing" test ! -s "${LOG}"
done
cs "${TREE}/cs" bogus; rc=$?
check "an unknown command is an error" test "${rc}" -eq 2
check "...that says so" mentions "no such command: bogus"

# --- dispatch ---------------------------------------------------------------------
for c in init build run start restart sync network; do
    cs "${TREE}/cs" "${c}" one "two words"
    check "cs ${c} runs host/${c}.sh with its arguments" logged "${c} one two words root=${TREE}"
done
cs "${TREE}/cs" tags base
check "cs tags passes its argument to tag-images.sh" logged "tag-images base root=${TREE}"
cs "${TREE}/cs" stage-plugins PLUGINS_UNUSED
check "cs stage-plugins runs plugins/stage.sh" logged "stage "
cs "${TREE}/cs" test
check "cs test runs every script in tests/" test "$(grep -c '^test-' "${LOG}")" -eq 2

# --- fetched with curl: no checkout around ------------------------------------------
cs bash -c "$(cat "${ROOT}/cs")" cs run --continue
check "from curl, cs downloads the tree and runs the command from it" logged "run --continue root="
check "...from the main version by default" logged "curl https://codeload.github.com/tartale/claude-sandbox/tar.gz/main"
root=$(sed -n 's/.*run --continue root=//p' "${LOG}")
check "...and removes the download afterwards" test ! -e "${root}"
cs env CS_REF=dev bash -c "$(cat "${ROOT}/cs")" cs run
check "CS_REF picks the version to download" logged "tar.gz/dev"
cs env CS_REF=latest bash -c "$(cat "${ROOT}/cs")" cs run
check "CS_REF=latest means main" logged "tar.gz/main"
cs env CS_REF=0123456789abcdef bash -c "$(cat "${ROOT}/cs")" cs run
check "a commit is fetched as given" logged "tar.gz/0123456789abcdef"
cs "${TREE}/cs" run
check "a checkout never downloads" not_logged "curl "

# --- development commands ------------------------------------------------------------
cs "${TREE}/cs" clean
check "cs clean removes the local image" logged "docker rmi ghcr.io/tartale/claude-sandbox:local"
cs env CS_IMAGE_TAG=t1 "${TREE}/cs" pull
check "cs pull pulls the tagged image" logged "docker pull ghcr.io/tartale/claude-sandbox:t1"
cs env CS_IMAGE_TAG=t2 CS_LANGUAGE_VERSIONS="go-1.25.10" PLUGINS=go "${TREE}/cs" image
check "cs image builds the Dockerfile in container/" logged "-f ${TREE}/container/Dockerfile"
check "...tagged for this machine" logged "-t ghcr.io/tartale/claude-sandbox:t2"
check "...with the Claude Code version, plugins and pins" logged "--build-arg CLAUDE_VERSION=9.9.9 --build-arg PLUGINS=plugins/.build --build-arg CS_LANGUAGE_VERSIONS=go-1.25.10"
check "...after staging the plugins" logged "stage go"
cs env CS_IMAGE_TAG=t3 "${TREE}/cs" push
check "cs push builds for both platforms and pushes" logged "--platform linux/amd64,linux/arm64 --push"
check "...tagging the version and latest" logged "-t ghcr.io/tartale/claude-sandbox:t3 -t ghcr.io/tartale/claude-sandbox:latest"

echo; echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
