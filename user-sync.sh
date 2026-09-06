#!/usr/bin/env bash
# Commit and push the user-scope config repo, so rules and memories written in
# this session reach the user's other machines.
set -euo pipefail

USER_CONFIG=/home/claude/.claude-user

if [ ! -d "${USER_CONFIG}" ]; then
    echo "no user config mounted (set CS_USER_CONFIG on the host)" >&2
    exit 1
fi

if [ ! -d "${USER_CONFIG}/.git" ]; then
    echo "${USER_CONFIG} is not a git repo; nothing to sync" >&2
    exit 1
fi

cd "${USER_CONFIG}"

if [ -z "$(git status --porcelain)" ]; then
    echo "user config already up to date"
    exit 0
fi

git add -A
git commit -q -m "${1:-Update user rules and memories}"

# Another machine may have pushed since the session-start pull.
git pull --rebase --quiet
git push --quiet
echo "user config pushed"
