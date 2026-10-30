#!/usr/bin/env bash
# cs pr list | approve [merge] N | merge N: review and merge pull requests as the repo owner. Run from a
# checkout, with gh signed in as the admin (not the sandbox's bot account).
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HOST_DIR}/lib.sh"

usage() { echo "usage: cs pr list | approve [merge] N [--yes] | merge N [--yes]   (--repo OWNER/NAME to name the repository)" >&2; exit 2; }

[ "$#" -gt 0 ] || usage
# Actions come first and run in the order given: cs pr approve merge 5 approves, then merges.
ACTIONS=()
NUMBER=""; YES=false; CS_REPO_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        list|approve|merge) [ -z "$NUMBER" ] || usage; ACTIONS+=("$1") ;;
        --yes) YES=true ;;
        --repo) CS_REPO_OVERRIDE=${2:?--repo needs OWNER/NAME}; shift ;;
        -*) usage ;;
        *) [ -z "$NUMBER" ] && NUMBER=$1 || usage ;;
    esac
    shift
done
[ "${#ACTIONS[@]}" -gt 0 ] || usage
export CS_REPO_OVERRIDE   # read by cs_owner_guard
cs_owner_guard

# What a pull request is, in a few lines: who wrote it, whether it is ready, and what it touches.
summary() {   # prints the facts; sets PR_AUTHOR, PR_STATE, PR_DECISION, BASE, PENDING, FAILING
    local row title
    row=$(gh pr view "$NUMBER" --repo "$CS_REPO" --json number,title,author,state,baseRefName,reviewDecision \
        --jq '[.number, .title, .author.login, .state, .baseRefName, (.reviewDecision // "none")] | @tsv') || cs_die "no pull request #$NUMBER in $CS_REPO"
    IFS=$'\t' read -r _ title PR_AUTHOR PR_STATE BASE PR_DECISION <<<"$row"
    PENDING=$(gh pr view "$NUMBER" --repo "$CS_REPO" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.status != "COMPLETED")] | length')
    FAILING=$(gh pr view "$NUMBER" --repo "$CS_REPO" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.conclusion != null and (.conclusion | IN("SUCCESS","SKIPPED","NEUTRAL") | not))] | length')
    echo "#$NUMBER  $title"
    echo "  by $PR_AUTHOR into $BASE, $PR_STATE, review: $PR_DECISION"
    echo "  checks: $PENDING pending, $FAILING failing"
    echo "  files:"
    gh pr view "$NUMBER" --repo "$CS_REPO" --json files --jq '.files[].path' | sed 's/^/    /'
}

has() { local x; for x in "${ACTIONS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

if has list; then
    [ "${#ACTIONS[@]}" = 1 ] || usage
    gh pr list --repo "$CS_REPO" --json number,title,author,reviewDecision \
        --jq '.[] | "#\(.number)  \(.author.login)  [\(.reviewDecision // "no review")]  \(.title)"'
    exit 0
fi
[ -n "$NUMBER" ] || usage
if has approve && has merge && [ "${ACTIONS[0]}" != approve ]; then cs_die "approve comes before merge: cs pr approve merge $NUMBER"; fi
[ "${#ACTIONS[@]}" -le 2 ] || usage

summary
[ "$PR_STATE" = OPEN ] || cs_die "#$NUMBER is $PR_STATE"
[ "$PENDING" = 0 ] || cs_die "checks are still running: wait, then run this again"
[ "$FAILING" = 0 ] || cs_die "checks are failing: it should not be approved or merged"
if has approve; then
    [ "$PR_AUTHOR" != "$CS_ME" ] || cs_die "you wrote #$NUMBER, and GitHub does not count your own approval: it is for the bot's pull requests"
elif [ "$PR_DECISION" != APPROVED ]; then
    cs_die "#$NUMBER is not approved (review: $PR_DECISION): cs pr approve $NUMBER first, or cs pr approve merge $NUMBER"
fi

if has approve && has merge; then QUESTION="Approve #$NUMBER, then merge it into $BASE and delete its branch?"
elif has approve; then QUESTION="Approve #$NUMBER?"
else QUESTION="Merge #$NUMBER into $BASE and delete its branch?"; fi
cs_confirm "$QUESTION" "$YES" || { echo "nothing done"; exit 1; }

for action in "${ACTIONS[@]}"; do
    case "$action" in
        approve) gh pr review "$NUMBER" --repo "$CS_REPO" --approve ;;
        merge)
            # An approval just given can take a moment to count.
            for try in 1 2 3 4 5; do
                gh pr merge "$NUMBER" --repo "$CS_REPO" --merge --delete-branch && break
                [ "$try" -lt 5 ] && [ "${ACTIONS[0]}" = approve ] || cs_die "could not merge #$NUMBER"
                sleep 2
            done ;;
    esac
done
