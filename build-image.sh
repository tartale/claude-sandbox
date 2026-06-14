#!/usr/bin/env bash
set -euo pipefail

REPO="tartale/claude-sandbox"
BRANCH="main"

CS_IMAGE_TAG="${CS_IMAGE_TAG:-custom}"
CS_IMAGE="ghcr.io/tartale/claude-sandbox:${CS_IMAGE_TAG}"
PLUGINS="${PLUGINS:-}"
LANGUAGE_VERSIONS="${LANGUAGE_VERSIONS:-}"
CLAUDE_VERSION="${CLAUDE_VERSION:-$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo latest)}"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Fetching build files from ${REPO}@${BRANCH}..."

# Download as a tarball to preserve git file permissions (100755 on scripts)
curl -fsSL "https://api.github.com/repos/${REPO}/tarball/${BRANCH}" \
    | tar -xz --strip-components=1 -C "$BUILD_DIR"

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
        # Built-in plugin name (e.g. "python3", "go")
        if [ ! -f "$BUILD_DIR/plugins/languages/${PLUGINS}.sh" ]; then
            echo "Unknown plugin: ${PLUGINS}" >&2
            echo "Available built-ins: cpp go java python2 python3 react ruby rust typescript" >&2
            exit 1
        fi
        PLUGINS_ARG="plugins/languages/${PLUGINS}.sh"
    fi
fi

BUILD_ARGS=(
    -t "$CS_IMAGE"
    --build-arg "CLAUDE_VERSION=$CLAUDE_VERSION"
)
[ -n "$PLUGINS_ARG" ]        && BUILD_ARGS+=(--build-arg "PLUGINS=$PLUGINS_ARG")
[ -n "$LANGUAGE_VERSIONS" ]  && BUILD_ARGS+=(--build-arg "LANGUAGE_VERSIONS=$LANGUAGE_VERSIONS")

echo "Building ${CS_IMAGE}..."
docker build "${BUILD_ARGS[@]}" "$BUILD_DIR"
echo "Pushing ${CS_IMAGE}..."
docker push "$CS_IMAGE"
echo "Done. Image pushed: ${CS_IMAGE}"
