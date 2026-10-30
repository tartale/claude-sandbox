#!/usr/bin/env bash
# Tests for claude-user-pull (and the clone-mode patch path of claude-user-sync):
# a local bare repo stands in for the user config repo, so nothing touches the network.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
CLONE="${WORK}/clone"
STAMP="${WORK}/stamp"
PATCH="${WORK}/claude-user.patch"
sed "s#/home/claude/.claude-user#${CLONE}#; s#/tmp/claude-user-pull.stamp#${STAMP}#" "${ROOT}/container/user-pull.sh" > "${WORK}/pull.sh"
sed "s#/home/claude/.claude-user#${CLONE}#; s#/workspace/.tmp/claude-user.patch#${PATCH}#" "${ROOT}/container/user-sync.sh" > "${WORK}/sync.sh"

PASS=0
FAIL=0
OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
mentions() { grep -qF -- "$1" <<<"${OUT}"; }
lacks() { ! mentions "$1"; }
silent() { [ -z "${OUT}" ]; }

# fresh_world -- a bare upstream with one commit, a clone of it (as the entrypoint
# makes it, with refs/sandbox/base), and a second checkout to push upstream changes from.
fresh_world() {
    find "${WORK}/up.git" "${WORK}/seed" "${CLONE}" "${WORK}/applied.patch" "${PATCH}" -delete 2>/dev/null
    git init -q --bare "${WORK}/up.git"; git -C "${WORK}/up.git" symbolic-ref HEAD refs/heads/main
    git clone -q "${WORK}/up.git" "${WORK}/seed" 2>/dev/null
    (cd "${WORK}/seed" && echo rules > CLAUDE.md && git add . && git commit -qm init && git branch -M main && git push -q origin main)
    git clone -q "${WORK}/up.git" "${CLONE}"
    git -C "${CLONE}" update-ref refs/sandbox/base HEAD
}
upstream_change() {   # FILE TEXT SUBJECT -- push a commit upstream
    (cd "${WORK}/seed" && echo "$2" > "$1" && git add . && git commit -qm "$3" && git push -q origin main)
}
pull() { OUT=$(CS_USER_CONFIG_REPO=o/r CS_USER_CONFIG_TOKEN=tok bash "${WORK}/pull.sh" "$@" 2>&1); }

# --- nothing to follow ------------------------------------------------------
fresh_world
OUT=$(env -u CS_USER_CONFIG_REPO bash "${WORK}/pull.sh" --hook 2>&1)
check "does nothing without CS_USER_CONFIG_REPO (a mounted checkout is live)" silent

# --- up to date -------------------------------------------------------------
pull; check "up to date, run by hand: says so" mentions "up to date"
rm -f "${STAMP}"; pull --hook; check "up to date, as a hook: prints nothing" silent

# --- a change upstream ------------------------------------------------------
fresh_world; upstream_change memory.md "new memory" "Add a memory"
rm -f "${STAMP}"; pull --hook
check "a hook reports the change" mentions "User preferences changed"
check "...with the commit subject" mentions "Add a memory"
check "...and the diff" mentions "+new memory"
check "the clone is brought up to date" test -f "${CLONE}/memory.md"
check "the patch base moves with it" test "$(git -C "${CLONE}" rev-parse refs/sandbox/base)" = "$(git -C "${CLONE}" rev-parse HEAD)"
rm -f "${STAMP}"; pull --hook; check "the next check finds nothing to say" silent

# --- throttling -------------------------------------------------------------
fresh_world; rm -f "${STAMP}"; pull --hook >/dev/null
upstream_change memory.md "later" "Later change"
pull --hook; check "a second hook call within five minutes does not even fetch" silent
echo 0 > "${STAMP}"; pull --hook
check "after five minutes it reports the change" mentions "Later change"

# --- local work is never overwritten ----------------------------------------
fresh_world; upstream_change memory.md "new memory" "Add a memory"
echo "mine" > "${CLONE}/mine.md"
rm -f "${STAMP}"; pull --hook
check "uncommitted local work: reports the change" mentions "Add a memory"
check "...but says it was not pulled" mentions "NOT pulled"
check "...and leaves the clone alone" test ! -f "${CLONE}/memory.md"
check "...keeping the local file" test -f "${CLONE}/mine.md"

fresh_world; upstream_change memory.md "new memory" "Add a memory"
(cd "${CLONE}" && echo mine > mine.md && git add . && git commit -qm "Local memory")
rm -f "${STAMP}"; pull --hook
check "an unapplied local commit also blocks the pull" mentions "NOT pulled"
check "...and is kept" test -f "${CLONE}/mine.md"

# --- a patch the user applied is not a change -------------------------------
fresh_world
(cd "${CLONE}" && echo mine > mine.md && git add . && git commit -qm "Local memory")
git -C "${CLONE}" format-patch --stdout refs/sandbox/base..HEAD > "${WORK}/applied.patch"
(cd "${WORK}/seed" && GIT_COMMITTER_DATE="2031-01-01T00:00:00" git am -q "${WORK}/applied.patch" && git push -q origin main)
rm -f "${STAMP}"; pull --hook
check "a locally committed change the user applied is not reported" silent
check "the clone lines up with upstream afterwards" test "$(git -C "${CLONE}" rev-parse HEAD)" = "$(git -C "${CLONE}" rev-parse origin/main)"
check "...and nothing pends for sync" test -z "$(git -C "${CLONE}" log --oneline refs/sandbox/base..HEAD)"

# --- an unreachable remote --------------------------------------------------
fresh_world; git -C "${CLONE}" remote set-url origin "${WORK}/nowhere.git"
rm -f "${STAMP}"; pull --hook; check "a failed fetch is silent as a hook" silent
pull; check "a failed fetch is reported when run by hand" mentions "could not fetch"

# --- claude-user-sync in clone mode -----------------------------------------
fresh_world
echo "memory" > "${CLONE}/new-memory.md"
OUT=$(CS_USER_CONFIG_REPO=o/r bash "${WORK}/sync.sh" "Add new-memory" 2>&1)
check "sync writes a patch rather than pushing" test -s "${PATCH}"
check "...containing the change" grep -q '^+memory' "${PATCH}"
check "...and says where it is" mentions "wrote"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
