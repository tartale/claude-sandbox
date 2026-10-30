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
