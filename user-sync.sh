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

# Cloned from CS_USER_CONFIG_REPO with a bot account that can only read it: push a
# branch to the bot's own fork and open a PR from there. The bot has no write
# access to the repo, so nothing here can change main.
if [ -n "${CS_USER_CONFIG_REPO:-}" ]; then
    git add -A
    git diff --cached --quiet || git commit -q -m "${1:-Update user rules and memories}"
    if [ -z "$(git log --oneline refs/sandbox/base..HEAD)" ]; then
        echo "user config already up to date"
        exit 0
    fi
    export GH_TOKEN="${CS_USER_CONFIG_TOKEN}"
    bot=$(gh api user --jq .login)
    fork="${bot}/${CS_USER_CONFIG_REPO#*/}"
    if ! gh api "repos/${fork}" >/dev/null 2>&1; then
        gh repo fork "${CS_USER_CONFIG_REPO}" --clone=false >&2
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            gh api "repos/${fork}" >/dev/null 2>&1 && break
            sleep 2
        done
    fi
    branch="sandbox/$(date -u +%Y%m%d-%H%M%S)"
    header="Authorization: Basic $(printf 'x-access-token:%s' "${CS_USER_CONFIG_TOKEN}" | base64 -w0)"
    GIT_CONFIG_GLOBAL=/dev/null git -c http.extraheader="${header}" \
        push --quiet "https://github.com/${fork}.git" "HEAD:refs/heads/${branch}"
    gh pr create --repo "${CS_USER_CONFIG_REPO}" --base main --head "${bot}:${branch}" \
        --title "${1:-Update user rules and memories}" \
        --body "Opened by claude-user-sync from a sandbox session."
    exit 0
fi

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
