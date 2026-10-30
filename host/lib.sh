# shellcheck shell=bash
# Shared by the host scripts; sourced, not run.

# cs_project_env -- works out the project the command is for and exports
#   CS_PROJECT_DIR   the project's root (default: the git root of the current directory)
#   CS_PROJECT_NAME  its repo name (default: from the origin remote, else the directory name)
#   CS_PROJECT_TAG   that name as an image tag and container-name suffix
# The project's .claude/sandbox stubs set the first two, so a command works from any directory.
cs_project_env() {
    : "${CS_PROJECT_DIR:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    if [ -z "${CS_PROJECT_NAME:-}" ]; then
        CS_PROJECT_NAME=$(git -C "$CS_PROJECT_DIR" remote get-url origin 2>/dev/null | sed -E 's#.*[/:]##; s#\.git$##') || true
        : "${CS_PROJECT_NAME:=$(basename "$CS_PROJECT_DIR")}"
    fi
    CS_PROJECT_TAG=$(printf '%s' "$CS_PROJECT_NAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_.\n-' '-')
    export CS_PROJECT_DIR CS_PROJECT_NAME CS_PROJECT_TAG
}

# --- owner commands (cs pr, cs release): they act on GitHub with your admin login ---------------

# cs_owner_guard -- refuse to run from a downloaded copy, and unless gh is signed in as an admin of
# the repo. Sets CS_REPO (OWNER/NAME; --repo overrides the current directory's) and CS_ME (your login).
cs_owner_guard() {
    [ -z "${CS_FETCHED:-}" ] || cs_die "run these from a checkout you have reviewed (./cs): they act with your admin login, so they do not run from a downloaded copy"
    command -v gh >/dev/null || cs_die "gh is required"
    CS_REPO=${CS_REPO_OVERRIDE:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}
    [ -n "$CS_REPO" ] || cs_die "could not tell which repository: run this inside its checkout, or pass --repo OWNER/NAME"
    CS_ME=$(gh api user --jq .login 2>/dev/null || true)
    [ -n "$CS_ME" ] || cs_die "gh is not signed in"
    [ "$(gh api "repos/$CS_REPO" --jq .permissions.admin 2>/dev/null || true)" = true ] \
        || cs_die "$CS_ME is not an admin of $CS_REPO: sign in as the owner (gh auth switch --user <you>)"
}

cs_die() { echo "error: $*" >&2; exit 1; }

# cs_confirm QUESTION YES -- asks [y/N] unless YES is true.
cs_confirm() {
    [ "$2" = true ] && return 0
    local a; read -r -p "$1 [y/N] " a
    [[ "$a" =~ ^[Yy] ]]
}
