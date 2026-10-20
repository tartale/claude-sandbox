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

# Cloned with a token that can push (CS_USER_CONFIG_WRITE=true): push a branch
# and open a PR. A ruleset requiring a PR on main is what keeps main safe.
if [ "${CS_USER_CONFIG_WRITE:-}" = "true" ] && [ -n "${CS_USER_CONFIG_REPO:-}" ]; then
    git add -A
    git diff --cached --quiet || git commit -q -m "${1:-Update user rules and memories}"
    if [ -z "$(git log --oneline refs/sandbox/base..HEAD)" ]; then
        echo "user config already up to date"
        exit 0
    fi
    branch="sandbox/$(date -u +%Y%m%d-%H%M%S)"
    header="Authorization: Basic $(printf 'x-access-token:%s' "${CS_USER_CONFIG_TOKEN}" | base64 -w0)"
    GIT_CONFIG_GLOBAL=/dev/null git -c http.extraheader="${header}" \
        push --quiet origin "HEAD:refs/heads/${branch}"
    GH_TOKEN="${CS_USER_CONFIG_TOKEN}" gh pr create --repo "${CS_USER_CONFIG_REPO}" \
        --base main --head "${branch}" --title "${1:-Update user rules and memories}" \
        --body "Opened by claude-user-sync from a sandbox session."
    exit 0
fi

# A read-only clone has no remote; hand the changes back as a patch to review
# and apply from a trusted checkout (git am < file).
if [ -z "$(git remote)" ]; then
    git add -A
    git diff --cached --quiet || git commit -q -m "${1:-Update user rules and memories}"
    patch=/workspace/.tmp/claude-user.patch
    mkdir -p "$(dirname "${patch}")"
    git format-patch --stdout refs/sandbox/base..HEAD > "${patch}"
    if [ -s "${patch}" ]; then
        echo "read-only user config: wrote ${patch}. Review it, then apply it from your claude-user checkout on the host:"
        echo "      git am < <project>/.tmp/claude-user.patch"
    else
        echo "user config already up to date"
    fi
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
