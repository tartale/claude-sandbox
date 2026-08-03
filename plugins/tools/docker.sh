#!/usr/bin/env bash
set -euo pipefail

# Installs the Docker CLI (client only) plus the Compose and Buildx plugins.
# The daemon is intentionally omitted: the sandbox is expected to talk to a
# Docker daemon on the host by bind-mounting its socket (Docker-out-of-Docker).

# shellcheck disable=SC1091
. /etc/os-release

apt-get update
apt-get install -y ca-certificates curl

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y \
  docker-ce-cli \
  docker-buildx-plugin \
  docker-compose-plugin
rm -rf /var/lib/apt/lists/*
