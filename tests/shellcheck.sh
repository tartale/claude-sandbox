#!/usr/bin/env bash
# Every shell script in the repo (and the stubs it ships) must double-quote its expansions
# (shellcheck SC2086). CI's shellcheck job only reports warnings, so this checks the info-level
# finding on its own. The files init writes (.envrc-cs, the stubs) are checked in init.sh's tests.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if ! command -v shellcheck >/dev/null; then
    echo "skip - shellcheck is not installed"
    exit 0
fi

# Tracked files in a checkout, every file in a downloaded tree; a script is a file with a
# bash or sh shebang, or a "shellcheck shell=" header (a sourced library).
candidates() {
    if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "${ROOT}" ls-files
    else
        (cd "${ROOT}" && find . -type f -not -path './.git/*' | sed 's#^\./##')
    fi
}
SCRIPTS=()
while IFS= read -r f; do
    [ -f "${ROOT}/${f}" ] || continue
    if head -n 2 "${ROOT}/${f}" 2>/dev/null | grep -qE '^#!.*(bash|/sh)|^# shellcheck shell='; then SCRIPTS+=("${ROOT}/${f}"); fi
done < <(candidates)

OUT=$(shellcheck -s bash --severity=info --include=SC2086 "${SCRIPTS[@]}" 2>&1); rc=$?
if [ "${rc}" -eq 0 ]; then
    echo "ok   - ${#SCRIPTS[@]} scripts have no unquoted expansions (SC2086)"
    echo; echo "1 passed, 0 failed"
else
    echo "FAIL - unquoted expansions (SC2086)"; echo "${OUT}" | sed 's/^/       /'
    echo; echo "0 passed, 1 failed"
    exit 1
fi
