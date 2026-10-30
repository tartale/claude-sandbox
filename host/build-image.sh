#!/usr/bin/env bash
set -euo pipefail

# The files the image is built from: the tree cs runs from (CS_ROOT).
CS_ROOT="${CS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

PUSH=true
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-push) PUSH=false ;;
        *) echo "usage: build-image.sh [--no-push]" >&2; exit 2 ;;
    esac
    shift
done

CS_IMAGE_TAG="${CS_IMAGE_TAG:-custom}"
CS_IMAGE_REPO="${CS_IMAGE_REPO:-ghcr.io/tartale/claude-sandbox}"
CS_IMAGE="${CS_IMAGE_REPO}:${CS_IMAGE_TAG}"
PLUGINS="${PLUGINS:-}"
CS_LANGUAGE_VERSIONS="${CS_LANGUAGE_VERSIONS:-}"
CS_NPM_REGISTRY="${CS_NPM_REGISTRY:-https://registry.npmjs.org/}"
CS_NPMRC="${CS_NPMRC:-}"   # npmrc file with the registry's credentials, mounted as a build secret
CLAUDE_VERSION="${CLAUDE_VERSION:-$(npm view --registry "$CS_NPM_REGISTRY" @anthropic-ai/claude-code version 2>/dev/null || echo latest)}"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Using build files from ${CS_ROOT}..."

# A copy, because plugins are staged into it; tar keeps file permissions.
tar -C "$CS_ROOT" --exclude=./.git --exclude=./.tmp -cf - . | tar -C "$BUILD_DIR" -xf -

# Resolve PLUGINS to a path relative to BUILD_DIR
PLUGINS_ARG=""
if [ -n "$PLUGINS" ]; then
    if echo "$PLUGINS" | grep -qE '^https?://'; then
        # Remote URL — download into a subdirectory so PLUGINS_DIR resolves correctly
        mkdir -p "$BUILD_DIR/plugins/custom"
        curl -fsSL "$PLUGINS" > "$BUILD_DIR/plugins/custom/plugin.sh"
        chmod +x "$BUILD_DIR/plugins/custom/plugin.sh"
        PLUGINS_ARG="plugins/custom/plugin.sh"
    elif [ -d "$PLUGINS" ]; then
        # Local directory — copy all .sh files into custom/
        mkdir -p "$BUILD_DIR/plugins/custom"
        find "$PLUGINS" -maxdepth 1 -name '*.sh' -exec cp {} "$BUILD_DIR/plugins/custom/" \;
        chmod +x "$BUILD_DIR/plugins/custom/"*.sh 2>/dev/null || true
        PLUGINS_ARG="plugins/custom"
    elif [ -f "$PLUGINS" ]; then
        # Local file
        mkdir -p "$BUILD_DIR/plugins/custom"
        cp "$PLUGINS" "$BUILD_DIR/plugins/custom/plugin.sh"
        chmod +x "$BUILD_DIR/plugins/custom/plugin.sh"
        PLUGINS_ARG="plugins/custom/plugin.sh"
    else
        # Built-in plugin name (e.g. "python3", "go", "docker")
        if [ -f "$BUILD_DIR/plugins/languages/${PLUGINS}.sh" ]; then
            PLUGINS_ARG="plugins/languages/${PLUGINS}.sh"
        elif [ -f "$BUILD_DIR/plugins/tools/${PLUGINS}.sh" ]; then
            PLUGINS_ARG="plugins/tools/${PLUGINS}.sh"
        else
            echo "Unknown plugin: ${PLUGINS}" >&2
            echo "Available built-ins: cpp go java python2 python3 react ruby rust typescript docker" >&2
            exit 1
        fi
    fi
fi

# The build always mounts an npmrc secret; without CS_NPMRC it is empty.
if [ -z "$CS_NPMRC" ]; then
    CS_NPMRC="$BUILD_DIR/.empty-npmrc"
    : > "$CS_NPMRC"
fi
[ -f "$CS_NPMRC" ] || { echo "CS_NPMRC is not a file: $CS_NPMRC" >&2; exit 1; }

BUILD_ARGS=(
    -t "$CS_IMAGE"
    --build-arg "CLAUDE_VERSION=$CLAUDE_VERSION"
    --build-arg "NPM_REGISTRY=$CS_NPM_REGISTRY"
    --secret "id=npmrc,src=$CS_NPMRC"
)
[ -n "$PLUGINS_ARG" ]        && BUILD_ARGS+=(--build-arg "PLUGINS=$PLUGINS_ARG")
[ -n "$CS_LANGUAGE_VERSIONS" ]  && BUILD_ARGS+=(--build-arg "CS_LANGUAGE_VERSIONS=$CS_LANGUAGE_VERSIONS")

echo "Building ${CS_IMAGE}..."
docker build -f "$BUILD_DIR/container/Dockerfile" "${BUILD_ARGS[@]}" "$BUILD_DIR"
if [ "$PUSH" = true ]; then
    echo "Pushing ${CS_IMAGE}..."
    docker push "$CS_IMAGE"
    echo "Done. Image pushed: ${CS_IMAGE}"
else
    echo "Done. Image built, not pushed: ${CS_IMAGE}"
fi
