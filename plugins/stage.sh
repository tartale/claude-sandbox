#!/usr/bin/env bash
set -euo pipefail

plugins="${1:-}"
[ -z "$plugins" ] && exit 0

plugins_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$plugins_root/.build"
mkdir -p "$build_dir"

if [ -d "$plugins" ]; then
    find "$plugins" -maxdepth 1 -name '*.sh' -exec cp {} "$build_dir/" \;
elif [ -f "$plugins" ]; then
    cp "$plugins" "$build_dir/plugin.sh"
elif [ -f "$plugins_root/languages/${plugins}.sh" ]; then
    # Built-in language plugin name (e.g. "go", "python3")
    cp "$plugins_root/languages/${plugins}.sh" "$build_dir/plugin.sh"
elif [ -f "$plugins_root/tools/${plugins}.sh" ]; then
    # Built-in tool plugin name (e.g. "docker")
    cp "$plugins_root/tools/${plugins}.sh" "$build_dir/plugin.sh"
else
    echo "Unknown plugin: ${plugins}" >&2
    echo "Available built-ins: cpp go java python2 python3 react ruby rust typescript docker" >&2
    exit 1
fi
