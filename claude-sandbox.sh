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

# Ensure the file exists before bind-mounting (Docker creates a directory
# instead of a file if the source path is absent).
touch "$HOME/.gitconfig"

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

# Files the user later runs on the host (git hooks and config, direnv, the env file, the
# .claude/sandbox launch scripts; plugin.sh stays writable)
# are mounted read-only so the agent cannot plant code in them.
# Only paths that already exist are mounted; Docker would otherwise create them
# as empty directories on the host.
PROTECT_ARGS=()
[ -d "$(pwd)/.git/hooks" ] && PROTECT_ARGS+=(-v "$(pwd)/.git/hooks:/workspace/.git/hooks:ro")
[ -f "$(pwd)/.git/config" ] && PROTECT_ARGS+=(-v "$(pwd)/.git/config:/workspace/.git/config:ro")
[ -f "$(pwd)/.envrc" ] && PROTECT_ARGS+=(-v "$(pwd)/.envrc:/workspace/.envrc:ro")
[ -f "$(pwd)/.claude/sandbox/ref" ] && PROTECT_ARGS+=(-v "$(pwd)/.claude/sandbox/ref:/workspace/.claude/sandbox/ref:ro")
for script in build restart run start sync; do
    [ -f "$(pwd)/.claude/sandbox/${script}.sh" ] && PROTECT_ARGS+=(-v "$(pwd)/.claude/sandbox/${script}.sh:/workspace/.claude/sandbox/${script}.sh:ro")
done
case "$CS_ENV_FILE" in
  "$(pwd)"/*) [ -f "$CS_ENV_FILE" ] && PROTECT_ARGS+=(-v "$CS_ENV_FILE:/workspace/${CS_ENV_FILE#"$(pwd)"/}:ro") ;;
esac

# Each project gets its own Claude state directory, mounted as ~/.claude and
# ~/.claude.json, so a sandbox sees only its own transcripts, plans and history and
# cannot plant settings, hooks or skills that run in Claude Code on the host. Every
# project is mounted at /workspace, so inside the container they all share the
# project key "-workspace"; the project's directory name names the host-side directory,
# so moving a project keeps its state (two projects with the same name share one).
CS_PROJECT_SLUG=$(basename "$(pwd)" | sed 's#[^a-zA-Z0-9._-]#-#g')
CS_PROJECT_STATE="${HOME}/.claude-sandbox/${CS_PROJECT_SLUG}"
mkdir -p "${CS_PROJECT_STATE}/.claude/projects/-workspace"
[ -e "${CS_PROJECT_STATE}/.claude.json" ] || echo '{"hasCompletedOnboarding":true}' > "${CS_PROJECT_STATE}/.claude.json"

# The container's claude user (UID 1000) writes to host-owned files through the
# host user's GID as a supplementary group; the setgid bit on the directories
# makes new files inherit it.
chmod g+rws "${CS_PROJECT_STATE}" "${CS_PROJECT_STATE}/.claude" "${CS_PROJECT_STATE}/.claude/projects" "${CS_PROJECT_STATE}/.claude/projects/-workspace" 2>/dev/null || true
chmod g+rw "${CS_PROJECT_STATE}/.claude.json" 2>/dev/null || true

# The OAuth credentials are the one thing copied in from the host's ~/.claude, and
# back out when the sandbox refreshed or renewed them (/login): whichever copy is
# newer wins, so a login in any sandbox carries to the others at their next start.
HOST_CREDS="${HOME}/.claude/.credentials.json"
SANDBOX_CREDS="${CS_PROJECT_STATE}/.claude/.credentials.json"
if [ -f "${HOST_CREDS}" ] && { [ ! -f "${SANDBOX_CREDS}" ] || [ "${HOST_CREDS}" -nt "${SANDBOX_CREDS}" ]; }; then
    cp -p "${HOST_CREDS}" "${SANDBOX_CREDS}"
elif [ -f "${SANDBOX_CREDS}" ] && { [ ! -f "${HOST_CREDS}" ] || [ "${SANDBOX_CREDS}" -nt "${HOST_CREDS}" ]; }; then
    mkdir -p "${HOME}/.claude"
    cp -p "${SANDBOX_CREDS}" "${HOST_CREDS}"
    chmod 600 "${HOST_CREDS}"
fi
chmod g+rw "${SANDBOX_CREDS}" 2>/dev/null || true

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
    -v "${CS_PROJECT_STATE}/.claude.json:/home/claude/.claude.json"
    -v "${CS_PROJECT_STATE}/.claude:/home/claude/.claude"
    -v "${CS_PROJECT_MEMORY}:/home/claude/.claude/projects/-workspace/memory"
    "${USER_CONFIG_ARGS[@]}"
    "${DOCKER_LOGIN_ARGS[@]}"
    -v "${HOME}/.gitconfig:/home/claude/.gitconfig:ro"
)

# When piped (e.g. curl | bash), stdin is not a TTY but /dev/tty still
# gives us access to the terminal — route docker's stdin through it.
if ! [ -t 0 ] && [ -c /dev/tty ]; then
    exec docker run "${DOCKER_ARGS[@]}" --env-file <(expand_env_file) "${CS_IMAGE}" "$@" </dev/tty
fi
exec docker run "${DOCKER_ARGS[@]}" --env-file <(expand_env_file) "${CS_IMAGE}" "$@"
