#!/usr/bin/env bash
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io/tartale/claude-sandbox}"
CLAUDE_VERSION="${CLAUDE_VERSION:-$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo latest)}"
CLAUDE_MAJOR_MINOR=$(echo "$CLAUDE_VERSION" | cut -d. -f1-2)
CLAUDE_MAJOR=$(echo "$CLAUDE_VERSION" | cut -d. -f1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANGUAGES=$(find "$SCRIPT_DIR/plugins/languages" -name "*.sh" -exec basename {} .sh \; | sort)

tag_base() {
    echo "Tagging base image with claude version $CLAUDE_VERSION..."
    docker buildx imagetools create --tag "$REGISTRY:$CLAUDE_VERSION"     "$REGISTRY:latest"
    docker buildx imagetools create --tag "$REGISTRY:$CLAUDE_MAJOR_MINOR" "$REGISTRY:latest"
    docker buildx imagetools create --tag "$REGISTRY:$CLAUDE_MAJOR"       "$REGISTRY:latest"
}

tag_languages() {
    for lang in $LANGUAGES; do
        case $lang in
            go)     ver=$(docker run --rm --entrypoint /bin/sh "$REGISTRY:$lang" -c "go version" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || ver="" ;;
            python) ver=$(docker run --rm --entrypoint /bin/sh "$REGISTRY:$lang" -c "python3 --version 2>&1" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || ver="" ;;
            java)   ver=$(docker run --rm --entrypoint /bin/sh "$REGISTRY:$lang" -c "java --version 2>&1" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || ver="" ;;
            rust)   ver=$(docker run --rm --entrypoint /bin/sh "$REGISTRY:$lang" -c "rustc --version 2>&1" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || ver="" ;;
            ruby)   ver=$(docker run --rm --entrypoint /bin/sh "$REGISTRY:$lang" -c "ruby --version 2>&1" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || ver="" ;;
            cpp)    ver=$(docker run --rm --entrypoint /bin/sh "$REGISTRY:$lang" -c "clang --version 2>&1" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || ver="" ;;
            *)      echo "  Unknown language $lang, skipping"; continue ;;
        esac

        if [ -z "$ver" ]; then
            echo "  Warning: $REGISTRY:$lang not found or version undetectable, skipping"
            continue
        fi

        maj=$(echo "$ver" | cut -d. -f1)
        majmin=$(echo "$ver" | cut -d. -f1-2)
        echo "Tagging $REGISTRY:$lang with version $ver..."
        docker buildx imagetools create --tag "$REGISTRY:$lang-$ver"    "$REGISTRY:$lang"
        docker buildx imagetools create --tag "$REGISTRY:$lang-$majmin" "$REGISTRY:$lang"
        docker buildx imagetools create --tag "$REGISTRY:$lang-$maj"    "$REGISTRY:$lang"
    done
}

case "${1:-all}" in
    base)      tag_base ;;
    languages) tag_languages ;;
    all)       tag_base; tag_languages ;;
    *)         echo "Usage: $0 [base|languages|all]"; exit 1 ;;
esac
