#!/usr/bin/env bash
set -e

if [[ "${DEBUG}" == "true" ]]; then set -x; fi

CS_IMAGE_TAG=${CS_IMAGE_TAG:-local}
CS_IMAGE_REPO="${CS_IMAGE_REPO:-ghcr.io/tartale/claude-sandbox}"
CS_IMAGE="${CS_IMAGE_REPO}:${CS_IMAGE_TAG}"
CONTAINER_NAME="${CS_CONTAINER_NAME:-claude-sandbox-$(basename "$(pwd)")-$(openssl rand -hex 2)}"
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
case "$CS_ENV_FILE" in
  /*) ;;                                         # already absolute
  *)  CS_ENV_FILE="${PWD}/${CS_ENV_FILE}" ;;
esac
if [ -f "$CS_ENV_FILE" ]; then
    if ! command -v envsubst >/dev/null 2>&1; then
        echo "envsubst is required to read ${CS_ENV_FILE}. Install it with:" >&2
        echo "  macOS:" >&2
        echo "      brew install gettext && brew link --force gettext" >&2
        echo "  Debian/Ubuntu:" >&2
        echo "      sudo apt-get install gettext-base" >&2
        exit 1
    fi
    CS_ENV_COMMANDS=$(grep -nE '\$\(|`' "$CS_ENV_FILE" | cut -d: -f1 | paste -sd, - || true)
    if [ -n "$CS_ENV_COMMANDS" ]; then
        echo "warning: ${CS_ENV_FILE} line(s) ${CS_ENV_COMMANDS} use command substitution, which is not run; the text is passed through literally." >&2
    fi
fi

# The env file is data, never shell: $VAR and \${VAR} are expanded from the host
# environment (only names the host actually exports, so a literal $ in a secret
# survives) and nothing in it is executed.
expand_env_file() {
    [ -f "$CS_ENV_FILE" ] || return 0
    # shellcheck disable=SC2046
    envsubst "$(printf '${%s} ' $(compgen -e))" < "$CS_ENV_FILE"
}

# Files the user later runs on the host (git hooks, direnv, the env file, the
# .claude/sandbox launch scripts; plugin.sh stays writable)
# are mounted read-only so the agent cannot plant code in them.
# Only paths that already exist are mounted; Docker would otherwise create them
# as empty directories on the host.
PROTECT_ARGS=()
[ -d "$(pwd)/.git/hooks" ] && PROTECT_ARGS+=(-v "$(pwd)/.git/hooks:/workspace/.git/hooks:ro")
[ -f "$(pwd)/.envrc" ] && PROTECT_ARGS+=(-v "$(pwd)/.envrc:/workspace/.envrc:ro")
for script in build run start sync; do
    [ -f "$(pwd)/.claude/sandbox/${script}.sh" ] && PROTECT_ARGS+=(-v "$(pwd)/.claude/sandbox/${script}.sh:/workspace/.claude/sandbox/${script}.sh:ro")
done
case "$CS_ENV_FILE" in
  "$(pwd)"/*) [ -f "$CS_ENV_FILE" ] && PROTECT_ARGS+=(-v "$CS_ENV_FILE:/workspace/${CS_ENV_FILE#"$(pwd)"/}:ro") ;;
esac

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

# User-scope rules and memories: a private git repo, cloned read-only by the
# entrypoint from CS_USER_CONFIG_REPO and CS_USER_CONFIG_TOKEN. They may come from
# the shell (passed by name here) or from the env file (which reaches the container
# on its own).
USER_CONFIG_ARGS=(-e CS_USER_CONFIG_REPO -e CS_USER_CONFIG_TOKEN)

# Opt-in: CS_DOCKER_CONFIG names a docker config directory whose config.json (registry
# logins) is shared read-only, so the container's docker CLI can pull and push private
# images. Anything in the container can read these credentials.
DOCKER_LOGIN_ARGS=()
if [ -n "${CS_DOCKER_CONFIG}" ]; then
    if [ ! -f "${CS_DOCKER_CONFIG}/config.json" ]; then
        echo "CS_DOCKER_CONFIG=${CS_DOCKER_CONFIG} has no config.json. Log in first:" >&2
        echo "      DOCKER_CONFIG=${CS_DOCKER_CONFIG} docker login" >&2
        exit 1
    fi
    if grep -qE '"(credsStore|credHelpers)"' "${CS_DOCKER_CONFIG}/config.json"; then
        echo "warning: ${CS_DOCKER_CONFIG}/config.json delegates to a credential helper that is not in the container; logins stored there will not work" >&2
    fi
    DOCKER_LOGIN_ARGS=(-v "${CS_DOCKER_CONFIG}/config.json:/home/claude/.docker/config.json:ro")
fi

case "${CS_DOCKER_FLAGS}" in
    *docker.sock*)
        echo "warning: the Docker socket is mounted; anything in the sandbox can start privileged containers and has root on this host." >&2 ;;
esac

LIMIT_ARGS=()
[ -n "${CS_PIDS_LIMIT}" ] && LIMIT_ARGS+=(--pids-limit "${CS_PIDS_LIMIT}")
[ -n "${CS_MEMORY}" ] && LIMIT_ARGS+=(--memory "${CS_MEMORY}")

# Deliberately unquoted: CS_DOCKER_FLAGS is a user-supplied string of separate docker arguments
# (e.g. "-v a:b -v c:d") that has to word-split into one array element each.
# shellcheck disable=SC2206
CS_DOCKER_FLAGS=(${CS_DOCKER_FLAGS})
if [ -t 0 ] || [ -c /dev/tty ]; then
    CS_DOCKER_FLAGS+=(-it)
else
    CS_DOCKER_FLAGS+=(-i)
fi

CS_HOSTS="${HOME}/.claude-sandbox-hosts"
grep -v '::1' /etc/hosts > "${CS_HOSTS}" || true   # host's real entries, minus IPv6
# This file replaces the /etc/hosts docker generates, which is where --add-host entries
# would land, so the ones in CS_DOCKER_FLAGS are written into it.
for i in "${!CS_DOCKER_FLAGS[@]}"; do
    case "${CS_DOCKER_FLAGS[i]}" in
        --add-host=*) entry="${CS_DOCKER_FLAGS[i]#--add-host=}" ;;
        --add-host) entry="${CS_DOCKER_FLAGS[i+1]:-}" ;;
        *) continue ;;
    esac
    addr="${entry#*:}"; addr="${addr#[}"; addr="${addr%]}"
    if [ "${addr}" = host-gateway ]; then
        echo "warning: --add-host ${entry} is not supported (the container's /etc/hosts is the host's own file); give the address instead" >&2
    else
        printf '%s %s\n' "${addr}" "${entry%%:*}" >> "${CS_HOSTS}"
    fi
done
chmod 644 "${CS_HOSTS}"


DOCKER_ARGS=(
    "${CS_DOCKER_FLAGS[@]}"
    --platform "${PLATFORM}"
    --name "${CONTAINER_NAME}"
    --cap-drop=ALL
    --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER --cap-add=SETUID --cap-add=SETGID
    --security-opt=no-new-privileges
    "${LIMIT_ARGS[@]}"
    -e CUID="$(id -u)"
    -e CGID="$(id -g)"
    -e CMASK="$(umask)"
    "${PLUGINS_ARGS[@]}"
    -v "$(pwd):/workspace"
    "${PROTECT_ARGS[@]}"
    -v "${HOME}/.claude.json:/home/claude/.claude.json"
    -v "${HOME}/.claude:/home/claude/.claude"
    -v "${CS_PROJECT_STATE}:/home/claude/.claude/projects/-workspace"
    -v "${CS_PROJECT_MEMORY}:/home/claude/.claude/projects/-workspace/memory"
    "${USER_CONFIG_ARGS[@]}"
    "${DOCKER_LOGIN_ARGS[@]}"
    -v "${HOME}/.gitconfig:/home/claude/.gitconfig:ro"
    -v "${CS_HOSTS}:/etc/hosts:ro"
)

# When piped (e.g. curl | bash), stdin is not a TTY but /dev/tty still
# gives us access to the terminal — route docker's stdin through it.
if ! [ -t 0 ] && [ -c /dev/tty ]; then
    exec docker run "${DOCKER_ARGS[@]}" --env-file <(expand_env_file) "${CS_IMAGE}" "$@" </dev/tty
fi
exec docker run "${DOCKER_ARGS[@]}" --env-file <(expand_env_file) "${CS_IMAGE}" "$@"
