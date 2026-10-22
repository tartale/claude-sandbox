#!/usr/bin/env bash
# Starts this project's sandbox interactively. Usage: .claude/sandbox/run.sh [claude args]
set -euo pipefail

THIS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The launcher version: CS_REF (a commit, tag or branch of tartale/claude-sandbox), else
# the commit init.sh pinned in the file "ref" next to this script, else main.
# CS_REF=latest follows main.
export CS_REF="${CS_REF:-$(cat "${THIS_SCRIPT_DIR}/ref" 2>/dev/null || echo main)}"
[ "${CS_REF}" != latest ] || CS_REF=main

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export CS_IMAGE_TAG="${CS_IMAGE_TAG:-claude-sandbox}"

# Name the container cs-<repo>, or cs-<repo>-2, -3... while another is running.
# A stopped container with the chosen name is removed, so every run is fresh
# (and CS_DOCKER_FLAGS may include --restart, which cannot be combined with --rm).
if [ -z "${CS_CONTAINER_NAME:-}" ]; then
    CS_CONTAINER_NAME="cs-claude-sandbox"
    n=1
    while [ "$(docker inspect -f '{{.State.Running}}' "$CS_CONTAINER_NAME" 2>/dev/null || true)" = true ]; do
        n=$((n + 1)); CS_CONTAINER_NAME="cs-claude-sandbox-$n"
    done
    docker rm "$CS_CONTAINER_NAME" >/dev/null 2>&1 || true
    export CS_CONTAINER_NAME
fi

exec /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/${CS_REF}/claude-sandbox.sh)" claude-sandbox --name "claude-sandbox" "$@"
