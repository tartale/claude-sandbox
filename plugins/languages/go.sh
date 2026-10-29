#!/usr/bin/env bash
set -euo pipefail

ARCH=$(dpkg --print-architecture)
GO_VERSION=$(echo "${CS_LANGUAGE_VERSIONS:-}" | tr ' ' '\n' | grep '^go-' | head -1) || true
GO_VERSION=${GO_VERSION:-$(curl -fsSL "https://go.dev/dl/?mode=json" | jq -r '.[0].version')}
GO_VERSION=${GO_VERSION/go-/go}

curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${ARCH}.tar.gz" \
  | tar -C /usr/local -xz

# Symlink into /usr/local/bin so tools are available without PATH changes
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
