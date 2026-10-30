#!/usr/bin/env bash
# cs release tag vX.Y.Z | approve [vX.Y.Z]: tag a release and approve its publish, as the repo owner.
# Run from a checkout, with gh signed in as the admin (not the sandbox's bot account).
#   tag      creates the tag on the default branch's latest commit (the 'release tags' ruleset lets
#            only you do this). The tag starts the release run, which then waits for your approval.
#   approve  approves that run's pending deployment (the 'release' environment).
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HOST_DIR}/lib.sh"

usage() { echo "usage: cs release tag vX.Y.Z [--yes] | approve [vX.Y.Z] [--yes]   (--repo OWNER/NAME to name the repository)" >&2; exit 2; }

[ "$#" -gt 0 ] || usage
ACTION=$1; shift
VERSION=""; YES=false; CS_REPO_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes) YES=true ;;
        --repo) CS_REPO_OVERRIDE=${2:?--repo needs OWNER/NAME}; shift ;;
        -*) usage ;;
        *) [ -z "$VERSION" ] && VERSION=$1 || usage ;;
    esac
    shift
done
export CS_REPO_OVERRIDE   # read by cs_owner_guard
cs_owner_guard

case "$ACTION" in
    tag)
        [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || cs_die "a version looks like v1.2.3 (got: ${VERSION:-none})"
        if gh api "repos/$CS_REPO/git/ref/tags/$VERSION" >/dev/null 2>&1; then cs_die "$VERSION already exists"; fi
        BRANCH=$(gh api "repos/$CS_REPO" --jq .default_branch)
        COMMIT=$(gh api "repos/$CS_REPO/commits/$BRANCH" --jq '[.sha, (.commit.message | split("\n")[0])] | @tsv')
        SHA=${COMMIT%%$'\t'*}; SUBJECT=${COMMIT#*$'\t'}
        echo "Tag $VERSION on $BRANCH at ${SHA:0:7}: $SUBJECT"
        cs_confirm "Create $VERSION?" "$YES" || { echo "not tagged"; exit 1; }
        if ERR=$(gh api -X POST "repos/$CS_REPO/git/refs" -f ref="refs/tags/$VERSION" -f sha="$SHA" 2>&1 >/dev/null); then
            echo "created $VERSION; the release run waits for your approval: cs release approve $VERSION"
        else
            echo "$ERR" | head -n 2 >&2
            cs_die "GitHub refused the tag: if the 'release tags' ruleset has no bypass for you, run init.sh again (it offers to add one)"
        fi
        ;;
    approve)
        if [ -n "$VERSION" ]; then
            RUN=$(gh run list --repo "$CS_REPO" --workflow release.yml --branch "$VERSION" --limit 1 --json databaseId,status --jq '.[0] | [.databaseId, .status] | @tsv' 2>/dev/null || true)
        else
            RUN=$(gh run list --repo "$CS_REPO" --workflow release.yml --status waiting --limit 1 --json databaseId,status --jq '.[0] | [.databaseId, .status] | @tsv' 2>/dev/null || true)
        fi
        [ -n "$RUN" ] || cs_die "no release run found${VERSION:+ for $VERSION}"
        RUN_ID=${RUN%%$'\t'*}; RUN_STATUS=${RUN#*$'\t'}
        [ "$RUN_STATUS" = waiting ] || cs_die "the release run ($RUN_ID) is $RUN_STATUS, not waiting for approval"
        ENVS=$(gh api "repos/$CS_REPO/actions/runs/$RUN_ID/pending_deployments" --jq '.[] | select(.current_user_can_approve) | [.environment.id, .environment.name] | @tsv')
        [ -n "$ENVS" ] || cs_die "nothing in run $RUN_ID is waiting for you to approve"
        echo "Release run $RUN_ID${VERSION:+ ($VERSION)} is waiting to deploy to: $(cut -f2 <<<"$ENVS" | paste -sd, -)"
        cs_confirm "Approve the release?" "$YES" || { echo "not approved"; exit 1; }
        ARGS=(); while IFS=$'\t' read -r id _; do ARGS+=(-F "environment_ids[]=$id"); done <<<"$ENVS"
        gh api -X POST "repos/$CS_REPO/actions/runs/$RUN_ID/pending_deployments" -f state=approved -f comment="approved with cs release approve" "${ARGS[@]}" >/dev/null
        echo "approved; the release is publishing: gh run watch $RUN_ID"
        ;;
    *) usage ;;
esac
