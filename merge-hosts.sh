#!/usr/bin/env bash
# Adds the host's /etc/hosts entries to the container's own, so both docker's entries
# (the container name, --add-host values including host-gateway) and the host's apply.
# docker's come first, so they win; IPv6 localhost is dropped from them.
# Usage: merge-hosts.sh HOST_COPY [TARGET]   (TARGET defaults to /etc/hosts)
set -euo pipefail

host_copy="$1"
target="${2:-/etc/hosts}"

merged=$(mktemp)
trap 'rm -f "${merged}"' EXIT
{
    grep -v '::1' "${target}" || true
    grep -vxFf "${target}" "${host_copy}" || true
} > "${merged}"
# In place: the target may be a file docker bind-mounts.
cat "${merged}" > "${target}"
