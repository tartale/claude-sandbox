# shellcheck shell=bash
# Sourced by entrypoint.sh: how git and gh reach the GitHub host this project lives on
# (github.com, GitHub Enterprise Server, or an Enterprise Cloud tenant such as corp.ghe.com).

# export_gh_env HOST TOKEN -- gh authenticates with GH_TOKEN on github.com and tenant hosts;
# Enterprise Server wants GH_ENTERPRISE_TOKEN and GH_HOST. Both tokens are set off github.com.
export_gh_env() {
    export GH_TOKEN="$2"
    if [ "$1" != github.com ]; then
        export GH_HOST="$1" GH_ENTERPRISE_TOKEN="$2"
    fi
}

# write_github_gitconfig HOST TOKEN CONFIG HELPER -- writes the git config that sends ssh
# remotes over https and hands the token to git through a credential helper script.
write_github_gitconfig() {
    local host=$1 token=$2 config=$3 helper=$4
    printf '[url "https://%s/"]\n\tinsteadOf = git@%s:\n[branch]\n\tautoSetupMerge = false\n' "$host" "$host" > "$config"
    if [ -n "$token" ]; then
        (umask 077; printf '#!/bin/sh\necho username=x-access-token\necho password=%s\n' "$token" > "$helper")
        chmod 700 "$helper"
        printf '[credential "https://%s"]\n\thelper = %s\n' "$host" "$helper" >> "$config"
    fi
}
