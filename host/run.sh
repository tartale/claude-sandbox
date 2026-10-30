#!/usr/bin/env bash
# Starts the project's sandbox interactively. Usage: cs run [claude args]
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HOST_DIR}/lib.sh"
cs_project_env

cd "$CS_PROJECT_DIR"
export CS_IMAGE_TAG="${CS_IMAGE_TAG:-$CS_PROJECT_TAG}"

# Name the container cs-<repo>, or cs-<repo>-2, -3... while another is running.
# A stopped container with the chosen name is removed, so every run is fresh
# (and CS_DOCKER_FLAGS may include --restart, which cannot be combined with --rm).
if [ -z "${CS_CONTAINER_NAME:-}" ]; then
    CS_CONTAINER_NAME="cs-${CS_PROJECT_TAG}"
    n=1
    while [ "$(docker inspect -f '{{.State.Running}}' "$CS_CONTAINER_NAME" 2>/dev/null || true)" = true ]; do
        n=$((n + 1)); CS_CONTAINER_NAME="cs-${CS_PROJECT_TAG}-$n"
    done
    docker rm "$CS_CONTAINER_NAME" >/dev/null 2>&1 || true
    export CS_CONTAINER_NAME
fi

exec bash "${HOST_DIR}/claude-sandbox.sh" --name "${CS_PROJECT_NAME}" "$@"
