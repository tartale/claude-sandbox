#!/usr/bin/env bash
# cs release tag [approve] vX.Y.Z | approve [vX.Y.Z]: tag a release and approve its publish, as the
# repo owner. Run from a checkout or the one-liner, with gh signed in as the admin (not the sandbox's bot account).
#   tag      creates the tag on the default branch's latest commit (the 'release tags' ruleset lets
#            only you do this). The tag starts the release run, which then waits for your approval.
#   approve  approves that run's pending deployment (the 'release' environment).
# Actions run in the order given: cs release tag approve v1.2.3 tags, then approves.
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HOST_DIR}/lib.sh"

usage() { echo "usage: cs release tag [approve] vX.Y.Z [--yes] | approve [vX.Y.Z] [--yes]   (--repo OWNER/NAME to name the repository)" >&2; exit 2; }

[ "$#" -gt 0 ] || usage
ACTIONS=()
VERSION=""; YES=false; CS_REPO_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        tag|approve) [ -z "$VERSION" ] || usage; ACTIONS+=("$1") ;;
        --yes) YES=true ;;
        --repo) CS_REPO_OVERRIDE=${2:?--repo needs OWNER/NAME}; shift ;;
        -*) usage ;;
        *) [ -z "$VERSION" ] && VERSION=$1 || usage ;;
    esac
    shift
done
[ "${#ACTIONS[@]}" -gt 0 ] && [ "${#ACTIONS[@]}" -le 2 ] || usage
export CS_REPO_OVERRIDE   # read by cs_owner_guard
cs_owner_guard

has() { local x; for x in "${ACTIONS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
if has tag && has approve && [ "${ACTIONS[0]}" != tag ]; then cs_die "tag comes before approve: cs release tag approve $VERSION"; fi

# find_run [WAIT_SECONDS] -- the release run for VERSION (or the one waiting), polling while it starts.
find_run() {
    local waited=0 run
    while :; do
        if [ -n "$VERSION" ]; then
            run=$(gh run list --repo "$CS_REPO" --workflow release.yml --branch "$VERSION" --limit 1 --json databaseId,status --jq '.[0] | [.databaseId, .status] | @tsv' 2>/dev/null || true)
        else
            run=$(gh run list --repo "$CS_REPO" --workflow release.yml --status waiting --limit 1 --json databaseId,status --jq '.[0] | [.databaseId, .status] | @tsv' 2>/dev/null || true)
        fi
        if [ -n "$run" ] && [ "${run#*$'\t'}" = waiting ]; then break; fi
        [ "$waited" -lt "${1:-0}" ] || break
        sleep 3; waited=$((waited + 3))
    done
    RUN=$run
}

# approve_run ASKED WAIT -- approve the waiting run's deployments, asking first unless ASKED.
approve_run() {
    local asked=$1 envs run_id run_status
    find_run "$2"
    [ -n "$RUN" ] || cs_die "no release run found${VERSION:+ for $VERSION}"
    run_id=${RUN%%$'\t'*}; run_status=${RUN#*$'\t'}
    [ "$run_status" = waiting ] || cs_die "the release run ($run_id) is $run_status, not waiting for approval"
    envs=$(gh api "repos/$CS_REPO/actions/runs/$run_id/pending_deployments" --jq '.[] | select(.current_user_can_approve) | [.environment.id, .environment.name] | @tsv')
    [ -n "$envs" ] || cs_die "nothing in run $run_id is waiting for you to approve"
    echo "Release run $run_id${VERSION:+ ($VERSION)} is waiting to deploy to: $(cut -f2 <<<"$envs" | paste -sd, -)"
    if [ "$asked" != true ]; then cs_confirm "Approve the release?" "$YES" || { echo "not approved"; exit 1; }; fi
    local args=() id
    while IFS=$'\t' read -r id _; do args+=(-F "environment_ids[]=$id"); done <<<"$envs"
    gh api -X POST "repos/$CS_REPO/actions/runs/$run_id/pending_deployments" -f state=approved -f comment="approved with cs release approve" "${args[@]}" >/dev/null
    echo "approved; the release is publishing: gh run watch $run_id"
}

if has tag; then
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || cs_die "a version looks like v1.2.3 (got: ${VERSION:-none})"
    if gh api "repos/$CS_REPO/git/ref/tags/$VERSION" >/dev/null 2>&1; then cs_die "$VERSION already exists"; fi
    BRANCH=$(gh api "repos/$CS_REPO" --jq .default_branch)
    COMMIT=$(gh api "repos/$CS_REPO/commits/$BRANCH" --jq '[.sha, (.commit.message | split("\n")[0])] | @tsv')
    SHA=${COMMIT%%$'\t'*}; SUBJECT=${COMMIT#*$'\t'}
    echo "Tag $VERSION on $BRANCH at ${SHA:0:7}: $SUBJECT"
    if has approve; then QUESTION="Create $VERSION, then approve its release?"; else QUESTION="Create $VERSION?"; fi
    cs_confirm "$QUESTION" "$YES" || { echo "nothing done"; exit 1; }
    if ERR=$(gh api -X POST "repos/$CS_REPO/git/refs" -f ref="refs/tags/$VERSION" -f sha="$SHA" 2>&1 >/dev/null); then
        echo "created $VERSION"
    else
        echo "$ERR" | head -n 2 >&2
        cs_die "GitHub refused the tag: if the 'release tags' ruleset has no bypass for you, run init.sh again (it offers to add one)"
    fi
    if has approve; then
        echo "waiting for the release run to start..."
        approve_run true "${CS_RELEASE_WAIT:-90}"
    else
        echo "the release run waits for your approval: cs release approve $VERSION"
    fi
else
    approve_run false 0
fi
