#!/usr/bin/env bash
set -e

if [[ "${DEBUG}" == "true" ]]; then trap "set +x" RETURN; set -x; fi

CS_IMAGE_TAG=${CS_IMAGE_TAG:-local}
CS_IMAGE="ghcr.io/tartale/claude-sandbox:${CS_IMAGE_TAG}"
CONTAINER_NAME="claude-sandbox-$(basename "$(pwd)")-$(openssl rand -hex 2)"
echo "Starting container: $CONTAINER_NAME"

case "$(uname -m)" in
  x86_64)  PLATFORM="linux/amd64" ;;
  aarch64) PLATFORM="linux/arm64" ;;
  *)       PLATFORM="linux/$(uname -m)" ;;
esac

# Ensure credential files exist before bind-mounting (Docker creates a
# directory instead of a file if the source path is absent).
touch "$HOME/.claude.json"
touch "$HOME/.gitconfig"
mkdir -p "$HOME/.claude"

# Allow the container's claude user (UID 1000) to write to host-owned files by
# adding the host user's GID as a supplementary group, and making the
# credential files group-writable. The setgid bit on .claude/ ensures new
# files created inside inherit the group rather than the container's default.
chmod g+rw "$HOME/.claude.json" 2>/dev/null || true
chmod g+rw "$HOME/.claude" 2>/dev/null || true
chmod g+s "$HOME/.claude" 2>/dev/null || true

PLUGINS_ARGS=()
if [ -n "$PLUGINS" ]; then
    PLUGINS_ARGS=(-e PLUGINS=/plugins -v "$PLUGINS:/plugins:ro")
fi

CS_ENV_FILE="${CS_ENV_FILE:-.env}"
# `source` searches $PATH when the filename has no slash, so make the path absolute.
case "$CS_ENV_FILE" in
  /*) ;;                                         # already absolute
  *)  CS_ENV_FILE="${PWD}/${CS_ENV_FILE}" ;;
esac
ENV_ARGS=()
if [ -f "$CS_ENV_FILE" ]; then
    # The file is sourced as shell on the host, and the container can edit it.
    # Flag anything that is not a plain NAME=value line (line numbers only, so
    # secrets never reach the terminal).
    CS_ENV_RISKY=$({ grep -nE '\$\(|`' "$CS_ENV_FILE"
                     grep -nEv '^[[:space:]]*(#|(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=|$)' "$CS_ENV_FILE"
                   } | cut -d: -f1 | sort -nu | paste -sd, - || true)
    if [ -n "$CS_ENV_RISKY" ]; then
        echo "warning: ${CS_ENV_FILE} is executed as shell on the host; line(s) ${CS_ENV_RISKY} contain commands or substitutions. Review them: the sandbox can edit this file." >&2
    fi
    set -a
    # shellcheck source=/dev/null
    source "$CS_ENV_FILE"
    set +a
    while IFS='=' read -r key _; do
        ENV_ARGS+=(-e "$key")
    done < <(grep -Ev '^\s*(#|$)' "$CS_ENV_FILE" | sed 's/^export //')
fi

# something in the if block unsets '-x'; reset it if needed
if [[ "${DEBUG}" == "true" ]]; then set -x; fi

# Every project is mounted at /workspace, so Claude Code derives the same
# project key ("-workspace") for all of them and piles every project's
# transcripts, plans and history into one bucket. Give each project its own
# host-side bucket and bind-mount it over that key. The slug matches the one
# Claude Code derives natively, so a project already run outside the sandbox
# keeps its history.
CS_PROJECT_SLUG=$(pwd | sed 's#[^a-zA-Z0-9-]#-#g')
CS_PROJECT_STATE="${HOME}/.claude/projects/${CS_PROJECT_SLUG}"
mkdir -p "${CS_PROJECT_STATE}"

# Project-scope memory lives inside the project so it is committed with the
# code and reaches the user's other machines on a git pull.
CS_PROJECT_MEMORY="$(pwd)/.claude/memory"
mkdir -p "${CS_PROJECT_MEMORY}"

# User-scope rules and memories: a private git repo, cloned on each machine.
USER_CONFIG_ARGS=()
if [ -n "${CS_USER_CONFIG}" ]; then
    if [ ! -d "${CS_USER_CONFIG}" ]; then
        echo "CS_USER_CONFIG=${CS_USER_CONFIG} does not exist; clone the user config repo there" >&2
        exit 1
    fi
    USER_CONFIG_ARGS=(-v "${CS_USER_CONFIG}:/home/claude/.claude-user")
fi

# Opt-in: share the host's docker registry logins (read-only) so the container's
# docker CLI can pull and push private images. Anything in the container can read
# these credentials.
DOCKER_LOGIN_ARGS=()
if [ "${CS_DOCKER_LOGIN}" = "true" ]; then
    CS_DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
    if [ ! -f "${CS_DOCKER_CONFIG}" ]; then
        echo "CS_DOCKER_LOGIN=true but ${CS_DOCKER_CONFIG} does not exist; run 'docker login' first" >&2
        exit 1
    fi
    if grep -qE '"(credsStore|credHelpers)"' "${CS_DOCKER_CONFIG}"; then
        echo "warning: ${CS_DOCKER_CONFIG} delegates to a credential helper that is not in the container; logins stored there will not work" >&2
    fi
    DOCKER_LOGIN_ARGS=(-v "${CS_DOCKER_CONFIG}:/home/claude/.docker/config.json:ro")
fi

case "${DOCKER_FLAGS}" in
    *docker.sock*)
        echo "warning: the Docker socket is mounted; anything in the sandbox can start privileged containers and has root on this host." >&2 ;;
esac

LIMIT_ARGS=()
[ -n "${CS_PIDS_LIMIT}" ] && LIMIT_ARGS+=(--pids-limit "${CS_PIDS_LIMIT}")
[ -n "${CS_MEMORY}" ] && LIMIT_ARGS+=(--memory "${CS_MEMORY}")

# Deliberately unquoted: DOCKER_FLAGS is a user-supplied string of separate docker arguments
# (e.g. "-v a:b -v c:d") that has to word-split into one array element each.
# shellcheck disable=SC2206
DOCKER_FLAGS=(${DOCKER_FLAGS})
if [ -t 0 ] || [ -c /dev/tty ]; then
    DOCKER_FLAGS+=(-it)
else
    DOCKER_FLAGS+=(-i)
fi

CS_HOSTS="${HOME}/.claude-sandbox-hosts"
grep -v '::1' /etc/hosts > "${CS_HOSTS}" || true   # host's real entries, minus IPv6
chmod 644 "${CS_HOSTS}"


DOCKER_ARGS=(
    "${DOCKER_FLAGS[@]}"
    --platform "${PLATFORM}"
    --name "${CONTAINER_NAME}"
    "${LIMIT_ARGS[@]}"
    "${ENV_ARGS[@]}"
    -e CUID="$(id -u)"
    -e CGID="$(id -g)"
    -e CMASK="$(umask)"
    "${PLUGINS_ARGS[@]}"
    -v "$(pwd):/workspace"
    -v "${HOME}/.claude.json:/home/claude/.claude.json"
    -v "${HOME}/.claude:/home/claude/.claude"
    -v "${CS_PROJECT_STATE}:/home/claude/.claude/projects/-workspace"
    -v "${CS_PROJECT_MEMORY}:/home/claude/.claude/projects/-workspace/memory"
    "${USER_CONFIG_ARGS[@]}"
    "${DOCKER_LOGIN_ARGS[@]}"
    -v "${HOME}/.gitconfig:/home/claude/.gitconfig:ro"
    -v "${CS_HOSTS}:/etc/hosts:ro"
    "${CS_IMAGE}" "$@"
)

# When piped (e.g. curl | bash), stdin is not a TTY but /dev/tty still
# gives us access to the terminal — route docker's stdin through it.
if ! [ -t 0 ] && [ -c /dev/tty ]; then
    exec docker run "${DOCKER_ARGS[@]}" </dev/tty
fi
exec docker run "${DOCKER_ARGS[@]}"
