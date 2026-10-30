#!/usr/bin/env bash
# Rebuilds the image, stops the project's container and starts it again in the
# background. Usage: cs restart [--no-push] [claude args]
# Without claude arguments it reuses those of the container it replaces. --no-push
# builds the image without pushing it.
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HOST_DIR}/lib.sh"
cs_project_env
NAME="${CS_CONTAINER_NAME:-cs-${CS_PROJECT_TAG}}"

BUILD_ARGS=()
if [ "${1:-}" = --no-push ]; then BUILD_ARGS=(--no-push); shift; fi

if [ "$#" -eq 0 ]; then
    # start.sh adds --name itself, so the recovered one is dropped. docker inspect ends
    # its output with a newline of its own; the empty arguments that makes are skipped.
    while IFS= read -r arg; do
        [ -n "$arg" ] || continue
        if [ "${skip:-false}" = true ]; then skip=false; continue; fi
        if [ "$arg" = --name ]; then skip=true; continue; fi
        set -- "$@" "$arg"
    done < <(docker inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' "$NAME" 2>/dev/null || true)
fi

"${HOST_DIR}/build.sh" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
docker stop "$NAME" >/dev/null 2>&1 || true
exec "${HOST_DIR}/start.sh" "$@"
