#!/usr/bin/env bash
set -euo pipefail

PYTHON_VERSION=$(echo "${LANGUAGE_VERSIONS:-}" | tr ' ' '\n' | grep '^python-' | head -1 | sed 's/python-//') || true

apt-get update
apt-get install -y \
  python3-dev \
  python3-pip \
  python3-venv \
  pipx
rm -rf /var/lib/apt/lists/*

# uv: fast Python package/project manager
curl -fsSL https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh

if [ -n "$PYTHON_VERSION" ]; then
    export UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
    uv python install "$PYTHON_VERSION"
    PYTHON_BIN=$(uv python find "$PYTHON_VERSION")
    ln -sf "$PYTHON_BIN" /usr/local/bin/python3
    ln -sf "$PYTHON_BIN" /usr/local/bin/python
fi
