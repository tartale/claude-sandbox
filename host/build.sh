#!/usr/bin/env bash
# Builds the project's sandbox image from its plugin.sh (or PLUGINS) and pushes it.
# Usage: cs build [--no-push]
# Then start it with cs run or cs start.
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HOST_DIR}/lib.sh"
cs_project_env

# PLUGINS (a built-in plugin name, a script or a directory) overrides the project's plugin.sh.
if [ -z "${PLUGINS:-}" ] && [ -f "${CS_PROJECT_DIR}/.claude/sandbox/plugin.sh" ]; then
    export PLUGINS="${CS_PROJECT_DIR}/.claude/sandbox/plugin.sh"
fi
export CS_IMAGE_TAG="${CS_IMAGE_TAG:-$CS_PROJECT_TAG}"

exec "${HOST_DIR}/build-image.sh" "$@"
