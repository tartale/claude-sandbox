#!/usr/bin/env bash
# cs pr list | approve N | merge N: review and merge pull requests as the repo owner. Run from a
# checkout, with gh signed in as the admin (not the sandbox's bot account).
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HOST_DIR}/lib.sh"

usage() { echo "usage: cs pr list | approve N [--yes] | merge N [--yes]   (--repo OWNER/NAME to name the repository)" >&2; exit 2; }

[ "$#" -gt 0 ] || usage
ACTION=$1; shift
NUMBER=""; YES=false; CS_REPO_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes) YES=true ;;
        --repo) CS_REPO_OVERRIDE=${2:?--repo needs OWNER/NAME}; shift ;;
        -*) usage ;;
        *) [ -z "$NUMBER" ] && NUMBER=$1 || usage ;;
    esac
    shift
done
export CS_REPO_OVERRIDE   # read by cs_owner_guard
cs_owner_guard

# What a pull request is, in a few lines: who wrote it, whether it is ready, and what it touches.
summary() {   # prints the facts; sets PR_AUTHOR, PR_STATE, PR_DECISION, PENDING, FAILING
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

need_number() { [ -n "$NUMBER" ] || usage; }

case "$ACTION" in
    list)
        gh pr list --repo "$CS_REPO" --json number,title,author,reviewDecision \
            --jq '.[] | "#\(.number)  \(.author.login)  [\(.reviewDecision // "no review")]  \(.title)"'
        ;;
    approve)
        need_number; summary
        [ "$PR_STATE" = OPEN ] || cs_die "#$NUMBER is $PR_STATE"
        [ "$PR_AUTHOR" != "$CS_ME" ] || cs_die "you wrote #$NUMBER, and GitHub does not count your own approval: it is for the bot's pull requests"
        [ "$PENDING" = 0 ] || cs_die "checks are still running: wait, then run this again"
        [ "$FAILING" = 0 ] || cs_die "checks are failing: it should not be approved"
        cs_confirm "Approve #$NUMBER?" "$YES" || { echo "not approved"; exit 1; }
        gh pr review "$NUMBER" --repo "$CS_REPO" --approve
        ;;
    merge)
        need_number; summary
        [ "$PR_STATE" = OPEN ] || cs_die "#$NUMBER is $PR_STATE"
        [ "$PENDING" = 0 ] || cs_die "checks are still running: wait, then run this again"
        [ "$FAILING" = 0 ] || cs_die "checks are failing"
        [ "$PR_DECISION" = APPROVED ] || cs_die "#$NUMBER is not approved (review: $PR_DECISION): cs pr approve $NUMBER first"
        cs_confirm "Merge #$NUMBER into $BASE and delete its branch?" "$YES" || { echo "not merged"; exit 1; }
        gh pr merge "$NUMBER" --repo "$CS_REPO" --merge --delete-branch
        ;;
    *) usage ;;
esac
