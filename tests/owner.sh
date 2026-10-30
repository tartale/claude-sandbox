#!/usr/bin/env bash
# Tests for cs pr and cs release (the repo owner's commands) against a stubbed gh: a state
# directory holds what GitHub would say, and every gh call is logged.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

BIN="${WORK}/bin"; D="${WORK}/gh"
mkdir -p "${BIN}" "${D}"
for f in /usr/bin/* /bin/*; do
    case "${f##*/}" in gh) continue ;; esac
    ln -sf "$f" "${BIN}/${f##*/}" 2>/dev/null || true
done
cat > "${BIN}/gh" <<'EOS'
#!/bin/bash
echo "gh $*" >> "$GHD/log"
cat_or() { if [ -f "$GHD/$1" ]; then cat "$GHD/$1"; else printf '%s\n' "$2"; fi; }
case "$*" in
    "repo view --json nameWithOwner -q .nameWithOwner") cat_or repo o/r ;;
    "api user --jq .login") cat_or me tartale ;;
    "api repos/o/r --jq .permissions.admin") cat_or admin true ;;
    "api repos/o/r --jq .default_branch") echo main ;;
    "api repos/o/r/commits/main --jq "*) printf 'abc1234def\tAdd a thing\n' ;;
    "api repos/o/r/git/ref/tags/"*) if [ -f "$GHD/tagexists" ]; then exit 0; else exit 1; fi ;;
    "api -X POST repos/o/r/git/refs "*) if [ -f "$GHD/tagfail" ]; then echo "Repository rule violations found" >&2; exit 1; fi ;;
    "pr list --repo o/r --json "*) cat_or prlist '#5  tartalebot  [REVIEW_REQUIRED]  Fix a thing' ;;
    "pr view 5 --repo o/r --json number,title,"*) cat_or prrow $'5\tFix a thing\ttartalebot\tOPEN\tmain\tREVIEW_REQUIRED' ;;
    "pr view 5 --repo o/r --json statusCheckRollup --jq "*'!= "COMPLETED"'*) cat_or pending 0 ;;
    "pr view 5 --repo o/r --json statusCheckRollup --jq "*"IN("*) cat_or failing 0 ;;
    "pr view 5 --repo o/r --json files --jq "*) printf 'host/init.sh\ntests/init.sh\n' ;;
    "pr view 9 --repo o/r "*) echo "no pull request" >&2; exit 1 ;;
    "pr review 5 --repo o/r --approve") ;;
    "pr merge 5 --repo o/r --merge --delete-branch") ;;
    "run list --repo o/r --workflow release.yml "*) [ -f "$GHD/run" ] && cat "$GHD/run" ;;
    "api repos/o/r/actions/runs/77/pending_deployments --jq "*) cat_or envs $'9\trelease' ;;
    "api -X POST repos/o/r/actions/runs/77/pending_deployments "*) ;;
esac
exit 0
EOS
chmod +x "${BIN}/gh"

PASS=0; FAIL=0; OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
mentions() { grep -qF -- "$1" <<<"${OUT}"; }
lacks() { ! mentions "$1"; }
logged() { grep -qF -- "$1" "${D}/log"; }
not_logged() { ! logged "$1"; }
world() { find "${D}" -mindepth 1 -delete; : > "${D}/log"; }
# run INPUT ENV... -- ARGS: feed INPUT on stdin, run a cs owner script with the given arguments
pr() { local in=$1; shift; OUT=$(printf "$in" | env -i PATH="${BIN}" HOME="${WORK}" GHD="${D}" "$@" 2>&1); return $?; }

# --- cs pr ----------------------------------------------------------------------------
world; pr '' bash "${ROOT}/host/pr.sh" list; rc=$?
check "cs pr list shows the open pull requests" mentions "#5  tartalebot  [REVIEW_REQUIRED]  Fix a thing"

world; pr 'y\n' bash "${ROOT}/host/pr.sh" approve 5; rc=$?
check "approve shows the title and author" mentions "#5  Fix a thing"
check "...the files it changes" mentions "host/init.sh"
check "...and the checks" mentions "checks: 0 pending, 0 failing"
check "...then approves on y" logged "gh pr review 5 --repo o/r --approve"
world; pr 'n\n' bash "${ROOT}/host/pr.sh" approve 5; rc=$?
check "approve does nothing on n" not_logged "pr review"
check "...and fails" test "${rc}" -ne 0
world; pr '' bash "${ROOT}/host/pr.sh" approve 5 --yes
check "--yes approves without asking" logged "gh pr review 5 --repo o/r --approve"
world; printf 'tartale' > "${D}/prrow"; printf '5\tMine\ttartale\tOPEN\tmain\tREVIEW_REQUIRED\n' > "${D}/prrow"
pr 'y\n' bash "${ROOT}/host/pr.sh" approve 5 --yes; rc=$?
check "you cannot approve your own pull request" test "${rc}" -ne 0
check "...it says why" mentions "GitHub does not count your own approval"
world; printf '2' > "${D}/pending"; pr 'y\n' bash "${ROOT}/host/pr.sh" approve 5 --yes; rc=$?
check "approve waits for running checks" mentions "checks are still running"
check "...and does not approve" not_logged "pr review"
world; printf '1' > "${D}/failing"; pr 'y\n' bash "${ROOT}/host/pr.sh" approve 5 --yes; rc=$?
check "approve refuses a pull request with failing checks" mentions "checks are failing"
world; pr '' bash "${ROOT}/host/pr.sh" approve 9 --yes; rc=$?
check "an unknown pull request is an error" mentions "no pull request #9"

world; pr 'y\n' bash "${ROOT}/host/pr.sh" merge 5; rc=$?
check "merge refuses a pull request that is not approved" mentions "is not approved"
check "...and does not merge" not_logged "pr merge"
world; printf '5\tFix a thing\ttartalebot\tOPEN\tmain\tAPPROVED\n' > "${D}/prrow"; pr 'y\n' bash "${ROOT}/host/pr.sh" merge 5
check "merge merges an approved pull request on y" logged "gh pr merge 5 --repo o/r --merge --delete-branch"
world; printf '5\tFix a thing\ttartalebot\tOPEN\tmain\tAPPROVED\n' > "${D}/prrow"; pr 'n\n' bash "${ROOT}/host/pr.sh" merge 5
check "...but not on n" not_logged "pr merge"
world; printf '5\tFix a thing\ttartalebot\tOPEN\tmain\tAPPROVED\n' > "${D}/prrow"; pr '' bash "${ROOT}/host/pr.sh" merge 5 --yes
check "--yes merges without asking" logged "pr merge 5"
world; printf '5\tFix a thing\ttartalebot\tOPEN\tmain\tAPPROVED\n' > "${D}/prrow"; printf '1' > "${D}/pending"; pr '' bash "${ROOT}/host/pr.sh" merge 5 --yes
check "merge waits for running checks" not_logged "pr merge"

world; printf 'false' > "${D}/admin"; pr '' bash "${ROOT}/host/pr.sh" approve 5 --yes; rc=$?
check "a login that is not the repo's admin is refused" mentions "is not an admin of o/r"
world; pr '' env CS_FETCHED=1 bash "${ROOT}/host/pr.sh" approve 5 --yes; rc=$?
check "the commands do not run from a downloaded copy" mentions "do not run from a downloaded copy"
check "...and touch nothing" test ! -s "${D}/log"
world; pr '' bash "${ROOT}/host/pr.sh" approve; rc=$?
check "approve needs a number" test "${rc}" -eq 2
world; printf 'x/y' > "${D}/repo"; pr '' bash "${ROOT}/host/pr.sh" list --repo o/r
check "--repo names the repository" logged "pr list --repo o/r"

# --- cs release -------------------------------------------------------------------------
world; pr 'y\n' bash "${ROOT}/host/release.sh" tag v1.2.3; rc=$?
check "tag shows the commit it will tag" mentions "Tag v1.2.3 on main at abc1234: Add a thing"
check "...then creates the tag on that commit on y" logged "gh api -X POST repos/o/r/git/refs -f ref=refs/tags/v1.2.3 -f sha=abc1234def"
check "...and points at the approval" mentions "cs release approve v1.2.3"
world; pr 'n\n' bash "${ROOT}/host/release.sh" tag v1.2.3
check "tag creates nothing on n" not_logged "-X POST"
world; pr '' bash "${ROOT}/host/release.sh" tag v1.2.3 --yes
check "--yes tags without asking" logged "refs/tags/v1.2.3"
world; pr '' bash "${ROOT}/host/release.sh" tag 1.2; rc=$?
check "a version must look like v1.2.3" mentions "a version looks like v1.2.3"
world; : > "${D}/tagexists"; pr '' bash "${ROOT}/host/release.sh" tag v1.2.3 --yes; rc=$?
check "a tag that exists is refused" mentions "v1.2.3 already exists"
world; : > "${D}/tagfail"; pr '' bash "${ROOT}/host/release.sh" tag v1.2.3 --yes; rc=$?
check "a refusal by the tag ruleset says what to do" mentions "run init.sh again"

world; printf '77\twaiting\n' > "${D}/run"; pr 'y\n' bash "${ROOT}/host/release.sh" approve v1.2.3; rc=$?
check "approve finds the release run for the tag" logged "run list --repo o/r --workflow release.yml --branch v1.2.3"
check "...says what it is waiting for" mentions "waiting to deploy to: release"
check "...and approves its pending deployment on y" logged "gh api -X POST repos/o/r/actions/runs/77/pending_deployments -f state=approved"
check "...for that environment" logged "-F environment_ids[]=9"
world; printf '77\twaiting\n' > "${D}/run"; pr 'n\n' bash "${ROOT}/host/release.sh" approve v1.2.3
check "approve does nothing on n" not_logged "-X POST"
world; printf '77\twaiting\n' > "${D}/run"; pr '' bash "${ROOT}/host/release.sh" approve --yes
check "without a version, approve takes the run that is waiting" logged "--status waiting"
check "...and approves it with --yes" logged "state=approved"
world; printf '77\tcompleted\n' > "${D}/run"; pr '' bash "${ROOT}/host/release.sh" approve v1.2.3 --yes; rc=$?
check "a run that is not waiting is refused" mentions "is completed, not waiting for approval"
world; pr '' bash "${ROOT}/host/release.sh" approve v1.2.3 --yes; rc=$?
check "no run is an error" mentions "no release run found for v1.2.3"
world; printf '77\twaiting\n' > "${D}/run"; : > "${D}/envs"; pr '' bash "${ROOT}/host/release.sh" approve v1.2.3 --yes; rc=$?
check "a run with nothing for you to approve is refused" mentions "nothing in run 77 is waiting for you"
world; pr '' env CS_FETCHED=1 bash "${ROOT}/host/release.sh" tag v1.2.3 --yes
check "release does not run from a downloaded copy either" test ! -s "${D}/log"

echo; echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
