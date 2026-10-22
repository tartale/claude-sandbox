#!/usr/bin/env bash
# Tests for claude-sandbox.sh. A stub `docker` records its arguments and the
# contents of --env-file, so nothing here needs a docker daemon.
# shellcheck disable=SC2016,SC2001  # literal $ in fixtures; sed for indenting
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

mkdir -p "${WORK}/bin" "${WORK}/home" "${WORK}/proj"
cat > "${WORK}/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Print each argument on its own line; expand --env-file to its contents.
while [ $# -gt 0 ]; do
    echo "ARG:$1"
    if [ "$1" = "--env-file" ]; then
        shift
        sed 's/^/ENV:/' "$1"
    fi
    shift
done
STUB
chmod +x "${WORK}/bin/docker"

# Without a real envsubst the launcher cannot read any env file, so stand one in
# (a plain copy) for the tests that only care about the docker arguments; the
# expansion tests below need the real one and are skipped.
REAL_ENVSUBST=false
if command -v envsubst >/dev/null 2>&1; then
    REAL_ENVSUBST=true
else
    printf '#!/bin/sh\ncat\n' > "${WORK}/bin/envsubst"
    chmod +x "${WORK}/bin/envsubst"
fi

PASS=0
FAIL=0
OUT=""

# run_launcher [VAR=value ...] -- run the launcher in a scratch project with a
# pty on stdin (as in a terminal) and the stub docker first on PATH. Output,
# including stderr, lands in $OUT; the launcher's exit status is returned.
run_launcher() {
    local rc
    OUT=$(cd "${WORK}/proj" && env -i PATH="${WORK}/bin:${PATH}" HOME="${WORK}/home" "$@" \
        script -qec "bash ${ROOT}/claude-sandbox.sh" /dev/null </dev/null 2>&1 | tr -d '\r')
    rc=${PIPESTATUS[0]}
    return "${rc}"
}

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }

# check NAME COMMAND... -- passes when the command succeeds.
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

has() { grep -qxF -- "$1" <<<"${OUT}"; }
lacks() { ! has "$1"; }
absent() { ! "$@"; }
mentions() { grep -qF -- "$1" <<<"${OUT}"; }

reset_project() {
    find "${WORK}/proj" -mindepth 1 -delete
    find "${WORK}/home" -mindepth 1 -delete
}

# --- per-project Claude state -------------------------------------------------
reset_project
SLUG=$(echo "${WORK}/proj" | sed 's#[^a-zA-Z0-9-]#-#g')
ST="${WORK}/home/.claude-sandbox/${SLUG}"
mkdir -p "${WORK}/home/.claude/projects/other"
echo secret > "${WORK}/home/.claude/projects/other/transcript"
echo '{"projects":{"/other":{}}}' > "${WORK}/home/.claude.json"
echo host-creds > "${WORK}/home/.claude/.credentials.json"
run_launcher
check "~/.claude is the project's own state dir" has "ARG:${ST}/.claude:/home/claude/.claude"
check "~/.claude.json is the project's own file" has "ARG:${ST}/.claude.json:/home/claude/.claude.json"
check "the host's ~/.claude is not mounted" lacks "ARG:${WORK}/home/.claude:/home/claude/.claude"
check "the host's ~/.claude.json is not mounted" lacks "ARG:${WORK}/home/.claude.json:/home/claude/.claude.json"
check "other projects' transcripts are not copied in" absent test -e "${ST}/.claude/projects/other"
check "the host's .claude.json contents are not copied in" absent grep -q /other "${ST}/.claude.json"
check "the credentials are seeded from the host" grep -qx host-creds "${ST}/.claude/.credentials.json"
touch -d '2001-01-01' "${WORK}/home/.claude/.credentials.json"
echo sandbox-creds > "${ST}/.claude/.credentials.json"
run_launcher
check "credentials the sandbox renewed are copied back" grep -qx sandbox-creds "${WORK}/home/.claude/.credentials.json"
check "...to a file only the user can read" test "$(stat -c %a "${WORK}/home/.claude/.credentials.json")" = 600
touch -d '2002-01-01' "${WORK}/home/.claude/.credentials.json"
echo host-new > "${WORK}/home/.claude/.credentials.json"
run_launcher
check "a newer host login replaces the sandbox's copy" grep -qx host-new "${ST}/.claude/.credentials.json"
rm -f "${WORK}/home/.claude/.credentials.json"
touch -d '2003-01-01' "${ST}/.claude/.credentials.json"
run_launcher
check "a sandbox login is stored on a host with none" test -f "${WORK}/home/.claude/.credentials.json"

# --- hardening flags --------------------------------------------------------
reset_project
run_launcher; rc=$?
check "launcher exits 0 with no config" test "${rc}" -eq 0
check "drops all capabilities" has "ARG:--cap-drop=ALL"
check "sets no-new-privileges" has "ARG:--security-opt=no-new-privileges"
check "uses the default image" mentions "ARG:ghcr.io/tartale/claude-sandbox:local"
check "no resource limits by default" lacks "ARG:--pids-limit"

reset_project
run_launcher CS_PIDS_LIMIT=64 CS_MEMORY=1g
check "CS_PIDS_LIMIT sets --pids-limit" has "ARG:64"
check "CS_MEMORY sets --memory" has "ARG:1g"

run_launcher CS_IMAGE_REPO=example.com/me/img CS_IMAGE_TAG=v1
check "CS_IMAGE_REPO and CS_IMAGE_TAG pick the image" has "ARG:example.com/me/img:v1"

# --- read-only protection of host-run files --------------------------------
reset_project
run_launcher
check "no protect mounts when the files are absent" lacks "ARG:${WORK}/proj/.envrc:/workspace/.envrc:ro"
check "...nor for .git/config" lacks "ARG:${WORK}/proj/.git/config:/workspace/.git/config:ro"

mkdir -p "${WORK}/proj/.git/hooks"
touch "${WORK}/proj/.envrc" "${WORK}/proj/.env" "${WORK}/proj/.git/config"
run_launcher
check ".git/config is mounted read-only" has "ARG:${WORK}/proj/.git/config:/workspace/.git/config:ro"
check ".git/hooks is mounted read-only" has "ARG:${WORK}/proj/.git/hooks:/workspace/.git/hooks:ro"
check ".envrc is mounted read-only" has "ARG:${WORK}/proj/.envrc:/workspace/.envrc:ro"
check ".env is mounted read-only" has "ARG:${WORK}/proj/.env:/workspace/.env:ro"

mkdir -p "${WORK}/proj/.claude/sandbox"
touch "${WORK}/proj/.claude/sandbox/restart.sh" "${WORK}/proj/.claude/sandbox/run.sh" "${WORK}/proj/.claude/sandbox/start.sh" "${WORK}/proj/.claude/sandbox/sync.sh" "${WORK}/proj/.claude/sandbox/plugin.sh"
run_launcher
touch "${WORK}/proj/.claude/sandbox/ref"
run_launcher
check "ref is mounted read-only" has "ARG:${WORK}/proj/.claude/sandbox/ref:/workspace/.claude/sandbox/ref:ro"
check "run.sh is mounted read-only" has "ARG:${WORK}/proj/.claude/sandbox/run.sh:/workspace/.claude/sandbox/run.sh:ro"
check "restart.sh is mounted read-only" has "ARG:${WORK}/proj/.claude/sandbox/restart.sh:/workspace/.claude/sandbox/restart.sh:ro"
check "start.sh is mounted read-only" has "ARG:${WORK}/proj/.claude/sandbox/start.sh:/workspace/.claude/sandbox/start.sh:ro"
check "sync.sh is mounted read-only" has "ARG:${WORK}/proj/.claude/sandbox/sync.sh:/workspace/.claude/sandbox/sync.sh:ro"
check "build.sh (absent) is not mounted" lacks "ARG:${WORK}/proj/.claude/sandbox/build.sh:/workspace/.claude/sandbox/build.sh:ro"
check "plugin.sh stays writable" lacks "ARG:${WORK}/proj/.claude/sandbox/plugin.sh:/workspace/.claude/sandbox/plugin.sh:ro"

# --- env file ---------------------------------------------------------------
if "${REAL_ENVSUBST}"; then
    reset_project
    printf 'A=$HOST_VAR\nB=${HOST_VAR}/x\nSECRET=pa$$word\nUNSET=$NOT_EXPORTED\n' > "${WORK}/proj/.env"
    run_launcher HOST_VAR=value
    check "expands exported \$VAR" has "ENV:A=value"
    check "expands exported \${VAR}" has "ENV:B=value/x"
    check "leaves a literal \$ in a secret alone" has 'ENV:SECRET=pa$$word'
    check "leaves unexported variables literal" has 'ENV:UNSET=$NOT_EXPORTED'

    printf 'X=$(echo hi)\nY=`id`\n' > "${WORK}/proj/.env"
    run_launcher
    check "does not run command substitution" has 'ENV:X=$(echo hi)'
    check "warns with line numbers about command substitution" mentions "line(s) 1,2 use command substitution"

    printf 'A=1\n' > "${WORK}/alt.env"
    run_launcher CS_ENV_FILE="${WORK}/alt.env"
    check "CS_ENV_FILE selects another file" has "ENV:A=1"
fi

reset_project
printf 'A=1\n' > "${WORK}/proj/.env"
mkdir -p "${WORK}/nobin"
for tool in bash env script tr sed grep cut paste cat id uname openssl basename touch mkdir chmod; do
    ln -sf "$(command -v "${tool}")" "${WORK}/nobin/${tool}"
done
OUT=$(cd "${WORK}/proj" && env -i PATH="${WORK}/nobin" HOME="${WORK}/home" \
    "$(command -v bash)" "${ROOT}/claude-sandbox.sh" 2>&1 </dev/null); rc=$?
check "missing envsubst stops the launcher" test "${rc}" -ne 0
check "missing envsubst prints install help" mentions "brew install gettext"

# --- user config and docker login -------------------------------------------
reset_project

run_launcher CS_DOCKER_CONFIG="${WORK}/home/.docker"; rc=$?
check "CS_DOCKER_CONFIG without a config file is an error" test "${rc}" -ne 0

mkdir -p "${WORK}/home/.docker"
echo '{"auths":{}}' > "${WORK}/home/.docker/config.json"
run_launcher CS_DOCKER_CONFIG="${WORK}/home/.docker"
check "CS_DOCKER_CONFIG mounts the config read-only" has "ARG:${WORK}/home/.docker/config.json:/home/claude/.docker/config.json:ro"

run_launcher CS_USER_CONFIG_REPO=a/b CS_USER_CONFIG_TOKEN=t; rc=$?
check "repo plus token passes both names through" test "${rc}" -eq 0
check "  ...the repo" has "ARG:CS_USER_CONFIG_REPO"
check "  ...the token (by name, never its value)" has "ARG:CS_USER_CONFIG_TOKEN"
check "  ...without mounting anything at the user config path" lacks ":/home/claude/.claude-user"

# --- --add-host ---------------------------------------------------------------
reset_project
run_launcher CS_DOCKER_FLAGS="--add-host=db.local:10.1.2.3 --add-host=gw:host-gateway"
check "--add-host values are passed to docker" has "ARG:--add-host=db.local:10.1.2.3"
check "...including host-gateway" has "ARG:--add-host=gw:host-gateway"
check "nothing is mounted over /etc/hosts" lacks "ARG:${WORK}/home/.claude-sandbox-hosts:/etc/hosts:ro"
run_launcher
check "...and no hosts file is written" test ! -e "${WORK}/home/.claude-sandbox-hosts"

# --- container name ---------------------------------------------------------
run_launcher CS_CONTAINER_NAME=my-box
check "CS_CONTAINER_NAME sets the container name" has "ARG:my-box"

# --- docker socket warning --------------------------------------------------
run_launcher CS_DOCKER_FLAGS="-v /var/run/docker.sock:/var/run/docker.sock"
check "warns when the docker socket is mounted" mentions "the Docker socket is mounted"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
