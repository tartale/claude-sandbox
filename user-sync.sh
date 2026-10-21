#!/usr/bin/env bash
# Commit the user-scope config clone and write the commits as a patch, so rules
# and memories written in this session can reach the user's other machines.
set -euo pipefail

USER_CONFIG=/home/claude/.claude-user

if [ ! -d "${USER_CONFIG}/.git" ]; then
    echo "no user config cloned (set CS_USER_CONFIG_REPO and CS_USER_CONFIG_TOKEN on the host)" >&2
    exit 1
fi

cd "${USER_CONFIG}"

# The clone is read-only; hand the changes back as a patch to review and apply
# from a trusted checkout (git am < file).
git add -A
git diff --cached --quiet || git commit -q -m "${1:-Update user rules and memories}"
patch=/workspace/.tmp/claude-user.patch
mkdir -p "$(dirname "${patch}")"
git format-patch --stdout refs/sandbox/base..HEAD > "${patch}"
if [ -s "${patch}" ]; then
    echo "wrote ${patch}. Review it, then apply it from your claude-user checkout on the host:"
    echo "      .claude/sandbox/sync.sh   (or: git am < <project>/.tmp/claude-user.patch)"
else
    echo "user config already up to date"
fi
