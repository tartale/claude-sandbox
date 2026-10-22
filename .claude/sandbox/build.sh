#!/usr/bin/env bash
# Builds this project's sandbox image from plugin.sh. Usage: .claude/sandbox/build.sh
# Then start it with run.sh or start.sh in this directory.
set -euo pipefail

THIS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The launcher version: CS_REF (a commit, tag or branch of tartale/claude-sandbox), else
# the commit init.sh pinned in the file "ref" next to this script, else main.
export CS_REF="${CS_REF:-$(cat "${THIS_SCRIPT_DIR}/ref" 2>/dev/null || echo main)}"

export PLUGINS="${THIS_SCRIPT_DIR}/plugin.sh"
export CS_IMAGE_TAG="${CS_IMAGE_TAG:-claude-sandbox}"

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/${CS_REF}/build-image.sh)"
