#!/usr/bin/env bash
# Brings the user-scope clone up to date with its repo and reports what changed.
# Usage: claude-user-pull [--hook]
# With --hook (a Claude Code UserPromptSubmit hook, see claude-settings.json) it checks
# at most every 5 minutes and prints only when something changed; whatever it prints
# lands in the agent's context.
set -euo pipefail

USER_CONFIG=/home/claude/.claude-user
STAMP=/tmp/claude-user-pull.stamp

# Only a cloned user scope has a remote to follow; a mounted checkout is live already.
[ -n "${CS_USER_CONFIG_REPO:-}" ] && [ -d "${USER_CONFIG}/.git" ] || exit 0

HOOK=false
[ "${1:-}" = "--hook" ] && HOOK=true
if [ "${HOOK}" = true ]; then
    now=$(date +%s)
    last=$(cat "${STAMP}" 2>/dev/null || echo 0)
    [ $((now - last)) -lt 300 ] && exit 0
    echo "${now}" > "${STAMP}"
fi

cd "${USER_CONFIG}"
header="Authorization: Basic $(printf 'x-access-token:%s' "${CS_USER_CONFIG_TOKEN:-}" | base64 -w0)"
if ! GIT_CONFIG_GLOBAL=/dev/null timeout 15 git -c http.extraheader="${header}" fetch --quiet origin 2>/dev/null; then
    [ "${HOOK}" = true ] || echo "could not fetch ${CS_USER_CONFIG_REPO}" >&2
    exit 0
fi

# Commits the user already applied from a patch (git am keeps the patch id) are not changes.
changes=$(git log --cherry-pick --right-only --format='  %h %s' HEAD...origin/main)
# Pending local work (uncommitted, or committed and not yet applied by the user)
# would be lost or tangled by moving the clone, so only report in that case.
if [ -z "$(git status --porcelain)" ] && ! git cherry origin/main HEAD | grep -q '^+'; then
    clean=true
else
    clean=false
fi

if [ -z "${changes}" ]; then
    # Nothing new; fall in line with origin when our commits have all landed there.
    if [ "${clean}" = true ]; then
        git reset --quiet --hard origin/main
        git update-ref refs/sandbox/base HEAD
    fi
    [ "${HOOK}" = true ] || echo "user preferences are up to date"
    exit 0
fi

diff=$(git diff HEAD origin/main -- . | head -n 300)
if [ "${clean}" = true ]; then
    git reset --quiet --hard origin/main
    git update-ref refs/sandbox/base HEAD
    echo "User preferences changed and are now current in ${USER_CONFIG}:"
else
    echo "User preferences changed upstream but were NOT pulled, because the clone has local changes."
    echo "Run claude-user-sync, have the user apply the patch, and start a new session to pick them up:"
fi
echo "${changes}"
echo
echo "${diff}"
echo
echo "Treat the above as the user's current rules and memories; they override anything older in your context."
