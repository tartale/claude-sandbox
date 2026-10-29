#!/usr/bin/env bash
set -euo pipefail

TS_VERSION=$(echo "${CS_LANGUAGE_VERSIONS:-}" | tr ' ' '\n' | grep '^typescript-' | head -1 | sed 's/typescript-//') || true

npm install -g \
  "typescript${TS_VERSION:+@$TS_VERSION}" \
  ts-node \
  tsx \
  @types/node
