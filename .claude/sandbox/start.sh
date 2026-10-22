#!/usr/bin/env bash
# Starts this project's sandbox in the background; claude waits on a detached tty.
# Usage: .claude/sandbox/start.sh [claude args]
set -euo pipefail

THIS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The launcher version: CS_REF (a commit, tag or branch of tartale/claude-sandbox), else
# the commit init.sh pinned in the file "ref" next to this script, else main.
# CS_REF=latest follows main.
export CS_REF="${CS_REF:-$(cat "${THIS_SCRIPT_DIR}/ref" 2>/dev/null || echo main)}"
[ "${CS_REF}" != latest ] || CS_REF=main

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export CS_IMAGE_TAG="${CS_IMAGE_TAG:-claude-sandbox}"
NAME="${CS_CONTAINER_NAME:-cs-claude-sandbox}"
export CS_CONTAINER_NAME="$NAME"

# Each start creates a fresh container, so changed variables and flags always
# apply. The container restarts with docker unless it was stopped; put --restart in
# CS_DOCKER_FLAGS to change that. No --rm: it cannot be combined with --restart.
if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true)" = true ]; then
    echo "$NAME is already running"
else
    docker rm "$NAME" >/dev/null 2>&1 || true   # a stopped one from an earlier start
    CS_DOCKER_FLAGS="-d -t --restart=unless-stopped ${CS_DOCKER_FLAGS:-}" \
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/${CS_REF}/claude-sandbox.sh)" claude-sandbox --name "claude-sandbox" "$@" >/dev/null
    echo "started $NAME"
fi
printf '\nAttach (detach with ctrl-p ctrl-q):\n\ndocker attach %s\n\nStop:\n\ndocker stop %s\n' "$NAME" "$NAME"
