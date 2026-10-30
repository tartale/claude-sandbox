#!/usr/bin/env bash
# cs: the claude-sandbox command. Needs no installation: run it from a checkout (./cs), or fetch
# and run it in one go:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/cs)" cs --help
#
# CS_REF (a commit, tag or branch of tartale/claude-sandbox; default main) picks the version
# that is fetched. A checkout runs its own files.
set -euo pipefail

CS_REPO=tartale/claude-sandbox

# --- find the tree the commands live in ---------------------------------------
if [ -z "${CS_ROOT:-}" ]; then
    self="${BASH_SOURCE[0]:-}"
    if [ -n "$self" ] && [ -f "$self" ] && [ -d "$(dirname "$self")/host" ]; then
        CS_ROOT=$(cd "$(dirname "$self")" && pwd)
    else
        # Fetched with curl: download the tree and run its copy of cs, so every command sees
        # the files next to it. A child process (not exec) so the download is removed after.
        ref="${CS_REF:-main}"; [ "$ref" != latest ] || ref=main
        tree=$(mktemp -d)
        trap 'rm -rf "$tree"' EXIT
        curl -fsSL "https://codeload.github.com/${CS_REPO}/tar.gz/${ref}" | tar -xz --strip-components=1 -C "$tree"
        rc=0
        CS_FETCHED=1 CS_ROOT="$tree" bash "$tree/cs" "$@" || rc=$?
        exit "$rc"
    fi
fi
export CS_ROOT
HOST="$CS_ROOT/host"

# --- help ---------------------------------------------------------------------
# One line per command: "name|group|summary". The usage text of each is in usage_<name>.
COMMANDS='init|Project|Set up a project: stubs, token, ruleset
build|Project|Build the project image from its plugin.sh and push it
run|Project|Start the project sandbox interactively
start|Project|Start the project sandbox in the background
restart|Project|Rebuild the image and restart the background sandbox
sync|Project|Apply the user-scope patch a session wrote
network|Host|Set up, check and remove the sandbox network
pr|Owner|List, approve and merge pull requests (as the repo owner)
release|Owner|Tag a release and approve its publish (as the repo owner)
test|Development|Run the tests in tests/
image|Development|Build the base image for this machine (no push)
push|Development|Build the base image for amd64 and arm64 and push it
pull|Development|Pull the base image
all|Development|Push the base image and every language variant
tags|Development|Tag the pushed images with version numbers
clean|Development|Remove the local image and the staged plugins
stage-plugins|Development|Stage PLUGINS for a build'

usage_init() { echo "Usage: cs init [--yes | --no]

  Set up the current project: the .claude/sandbox stubs, .envrc-cs and .env entries, an
  optional GitHub token (for you or a separate bot account), ghcr.io login and the branch and tag rulesets. Run it on the host, from the
  project root. --yes and --no answer the yes/no questions for unattended runs."; }
usage_build() { echo "Usage: cs build [--no-push]

  Build the project's image from .claude/sandbox/plugin.sh and push it to
  CS_IMAGE_REPO:CS_IMAGE_TAG. --no-push builds it for this machine only."; }
usage_run() { echo "Usage: cs run [CLAUDE ARGS]...

  Start the project's sandbox with Claude Code in your terminal. Arguments go to claude."; }
usage_start() { echo "Usage: cs start [CLAUDE ARGS]...

  Start the project's sandbox detached. A container that is already running is left alone."; }
usage_restart() { echo "Usage: cs restart [--no-push] [CLAUDE ARGS]...

  Rebuild the image, stop the project's container and start it again. Without arguments it
  reuses those of the container it replaces."; }
usage_sync() { echo "Usage: cs sync [apply | show | status]

  Handle the patch a session wrote with claude-user-sync: apply it to your user-config
  checkout and push it (default), page through it, or say whether one is waiting."; }
usage_network() { echo "Usage: cs network setup bridge|macvlan|ipvlan [OPTIONS] | check [LAN_HOST] | status | remove

  Set up the sandbox network, once per host. See docs/security.md. Run cs network without
  arguments for every option."; }
usage_pr() { echo "Usage: cs pr list | approve N [--yes] | merge N [--yes]

  As the repo owner, with gh signed in as the admin (not the sandbox's bot): list the open pull
  requests, approve one (after its author, checks and files are shown), or merge an approved one.
  --yes skips the question. --repo OWNER/NAME names the repository (default: the current directory's).
  Run from a checkout (./cs): these act with your admin login, so they do not run from a download."; }
usage_release() { echo "Usage: cs release tag vX.Y.Z [--yes] | approve [vX.Y.Z] [--yes]

  As the repo owner: tag the default branch's latest commit as a release (the tag ruleset lets only you
  do it), then approve the release run that waits for you. --yes skips the question. --repo OWNER/NAME
  names the repository. Run from a checkout (./cs), not a download."; }
usage_test() { echo "Usage: cs test

  Run every script in tests/ (needs a checkout)."; }
usage_image() { echo "Usage: cs image

  Build the base image for this machine without pushing it. PLUGINS, CS_IMAGE_TAG,
  CS_LANGUAGE_VERSIONS and CLAUDE_VERSION apply (default tag: local)."; }
usage_push() { echo "Usage: cs push

  Build the base image for linux/amd64 and linux/arm64 and push it as CS_IMAGE_TAG and latest."; }
usage_pull() { echo "Usage: cs pull

  Pull ghcr.io/tartale/claude-sandbox:CS_IMAGE_TAG."; }
usage_all() { echo "Usage: cs all

  cs push, then a pushed image for every plugin in plugins/languages."; }
usage_tags() { echo "Usage: cs tags [base | languages | all]

  Tag the pushed images with their version numbers (default: all)."; }
usage_clean() { echo "Usage: cs clean

  Remove the local image and plugins/.build."; }
usage_stage_plugins() { echo "Usage: cs stage-plugins

  Stage PLUGINS (a built-in plugin name, a script or a directory) into plugins/.build."; }

print_help() {
    echo "Usage: cs [OPTIONS] COMMAND [ARGS]..."
    echo
    echo "  Run Claude Code in a Docker sandbox, with your project mounted at /workspace."
    echo
    echo "Options:"
    echo "  --help  Show this message and exit."
    local group g name rest
    for g in Project Host Owner Development; do
        echo
        echo "$g commands:"
        while IFS='|' read -r name group rest; do
            [ "$group" = "$g" ] && printf '  %-14s %s\n' "$name" "$rest"
        done <<<"$COMMANDS"
    done
    echo
    echo "Run cs COMMAND --help for a command's options."
}

command_exists() { grep -q "^$1|" <<<"$COMMANDS"; }

# --- the development commands (the ones the Makefile used to hold) ---------------
dev_env() {
    CS_IMAGE_TAG="${CS_IMAGE_TAG:-local}"
    CS_IMAGE_REPO="${CS_IMAGE_REPO:-ghcr.io/tartale/claude-sandbox}"
    CS_IMAGE="${CS_IMAGE_REPO}:${CS_IMAGE_TAG}"
    CLAUDE_VERSION="${CLAUDE_VERSION:-$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo latest)}"
    BUILD_ARGS=(-f "$CS_ROOT/container/Dockerfile" --build-arg "CLAUDE_VERSION=$CLAUDE_VERSION")
    [ -z "${PLUGINS:-}" ] || BUILD_ARGS+=(--build-arg "PLUGINS=plugins/.build")
    [ -z "${CS_LANGUAGE_VERSIONS:-}" ] || BUILD_ARGS+=(--build-arg "CS_LANGUAGE_VERSIONS=$CS_LANGUAGE_VERSIONS")
    return 0
}
cmd_stage_plugins() { "$CS_ROOT/plugins/stage.sh" "${PLUGINS:-}"; }
cmd_test() {
    local t
    for t in "$CS_ROOT"/tests/*.sh; do bash "$t" || return 1; done
}
cmd_clean() {
    dev_env
    docker rmi "$CS_IMAGE" 2>/dev/null || true
    rm -rf "$CS_ROOT/plugins/.build"
}
cmd_pull() { dev_env; docker pull "$CS_IMAGE"; }
cmd_image() {
    dev_env; cmd_stage_plugins
    if docker buildx inspect multi-platform >/dev/null 2>&1 || docker buildx create --driver docker-container --use multi-platform >/dev/null 2>&1; then
        docker buildx use multi-platform
        (cd "$CS_ROOT" && docker buildx build --load -t "$CS_IMAGE" "${BUILD_ARGS[@]}" .)
    else
        (cd "$CS_ROOT" && docker build -t "$CS_IMAGE" "${BUILD_ARGS[@]}" .)
    fi
}
cmd_push() {
    dev_env; cmd_stage_plugins
    (cd "$CS_ROOT" && docker buildx build --platform linux/amd64,linux/arm64 --push \
        -t "$CS_IMAGE" -t "${CS_IMAGE_REPO}:latest" "${BUILD_ARGS[@]}" .)
}
cmd_all() {
    local plugin lang
    cmd_push
    for plugin in "$CS_ROOT"/plugins/languages/*.sh; do
        lang=$(basename "$plugin" .sh)
        echo "Building ${CS_IMAGE_REPO}:$lang..."
        (cd "$CS_ROOT" && docker buildx build --platform linux/amd64,linux/arm64 --push \
            -t "${CS_IMAGE_REPO}:$lang" -f container/Dockerfile \
            --build-arg "PLUGINS=plugins/languages/$lang.sh" --build-arg "CLAUDE_VERSION=$CLAUDE_VERSION" .)
    done
}
cmd_tags() { "$HOST/tag-images.sh" "${1:-all}"; }

# --- dispatch ---------------------------------------------------------------------
[ "$#" -gt 0 ] || { print_help; exit 0; }
case "$1" in
    -h|--help|help) print_help; exit 0 ;;
esac
cmd=$1; shift
command_exists "$cmd" || { echo "cs: no such command: $cmd" >&2; echo "Run cs --help for the commands." >&2; exit 2; }
case "${1:-}" in
    -h|--help) "usage_${cmd//-/_}"; exit 0 ;;
esac
case "$cmd" in
    init|build|run|start|restart|sync|network|pr|release) exec bash "$HOST/$cmd.sh" "$@" ;;
    *) "cmd_${cmd//-/_}" "$@" ;;
esac
