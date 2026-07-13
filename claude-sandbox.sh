#!/usr/bin/env bash
set -e

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
ENV_ARGS=()
if [ -f "$CS_ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$CS_ENV_FILE"
    set +a
    while IFS='=' read -r key _; do
        ENV_ARGS+=(-e "$key")
    done < <(grep -Ev '^\s*(#|$)' "$CS_ENV_FILE" | sed 's/^export //')
fi

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
    --network=host
    --name "${CONTAINER_NAME}"
    "${ENV_ARGS[@]}"
    -e CUID="$(id -u)"
    -e CGID="$(id -g)"
    -e CMASK="$(umask)"
    "${PLUGINS_ARGS[@]}"
    -v "$(pwd):/workspace"
    -v "${HOME}/.claude.json:/home/claude/.claude.json"
    -v "${HOME}/.claude:/home/claude/.claude"
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
