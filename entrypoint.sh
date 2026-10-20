#!/bin/bash
set -e

GITHUB_TOKEN="$CS_GITHUB_TOKEN"
export GH_TOKEN="$CS_GITHUB_TOKEN"

existing_group=$(getent group "${CGID}" 2>/dev/null | cut -d: -f1)
if [ -n "$existing_group" ] && [ "$existing_group" != "claude" ]; then
    groupmod -g "$(awk -F: 'BEGIN{max=65000} $3>max{max=$3} END{print max+1}' /etc/group)" "$existing_group"
fi
groupmod -g "${CGID}" claude

existing_user=$(getent passwd "${CUID}" 2>/dev/null | cut -d: -f1)
if [ -n "$existing_user" ] && [ "$existing_user" != "claude" ]; then
    usermod -u "$(awk -F: 'BEGIN{max=65000} $3>max{max=$3} END{print max+1}' /etc/passwd)" "$existing_user"
fi
usermod -u "${CUID}" claude

if [ -n "$PLUGINS" ]; then
    install-plugins.sh "$PLUGINS"
fi

# User-scope config: cloned with a token scoped to that one repo. The token stays
# in the environment so claude-user-sync can push a branch and open a PR; a
# ruleset on the repo must require a PR to change main, so a session can propose
# changes to the rules but never apply them.
if [ -n "$CS_USER_CONFIG_REPO" ]; then
    user_config=/home/claude/.claude-user
    if GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
        GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$CS_USER_CONFIG_TOKEN" | base64 -w0)" \
        git clone --quiet "https://github.com/${CS_USER_CONFIG_REPO}.git" "$user_config"; then
        # claude-user-sync opens its PR for the commits made since this ref.
        git -C "$user_config" update-ref refs/sandbox/base HEAD
        chown -R claude:claude "$user_config"
    else
        echo "warning: could not clone ${CS_USER_CONFIG_REPO}; the user scope is disabled" >&2
    fi
fi

printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' > /tmp/gitconfig
if [ -n "$GITHUB_TOKEN" ]; then
    (umask 077; printf '#!/bin/sh\necho username=x-access-token\necho password=%s\n' "$GITHUB_TOKEN" > /tmp/git-credential-github-token)
    chown claude:claude /tmp/git-credential-github-token
    chmod 700 /tmp/git-credential-github-token
    printf '[credential "https://github.com"]\n\thelper = /tmp/git-credential-github-token\n' >> /tmp/gitconfig
fi
# GIT_CONFIG_GLOBAL points at this file, which hides the host's ~/.gitconfig. Copy
# only the identity: the rest of the host file (path rewrites, hooks paths) does
# not apply in the container.
git_name=$(git config -f /home/claude/.gitconfig user.name 2>/dev/null || true)
git_email=$(git config -f /home/claude/.gitconfig user.email 2>/dev/null || true)
if [ -n "$git_name" ] && [ -n "$git_email" ]; then
    git config -f /tmp/gitconfig user.name "$git_name"
    git config -f /tmp/gitconfig user.email "$git_email"
fi
chmod a+r /tmp/gitconfig

CLAUDE_ARGS=$(printf '%q ' "$@")
export CLAUDE_ARGS

# grant access to a bind-mounted docker socket, if present
if [ -S /var/run/docker.sock ]; then
    docker_gid=$(stat -c '%g' /var/run/docker.sock)
    docker_group=$(getent group "$docker_gid" | cut -d: -f1)
    if [ -z "$docker_group" ]; then
        docker_group=dockerhost
        groupadd -g "$docker_gid" "$docker_group"
    fi
    usermod -aG "$docker_group" claude
fi

# Host paths leaked in through the env file (e.g. TMPDIR exported by direnv)
# do not exist inside the container. claude would try to create the whole path
# from / as the unprivileged claude user and die with
# "EACCES: permission denied, mkdir '/<first-component>'".
if [ -n "$TMPDIR" ] && [ ! -d "$TMPDIR" ]; then
    echo "warning: TMPDIR=$TMPDIR does not exist in the container; using /tmp" >&2
    export TMPDIR=/tmp
fi

su -m -s /bin/bash claude << 'EOF'
set -e
export HOME=/home/claude
umask ${CMASK}

export GIT_CONFIG_GLOBAL=/tmp/gitconfig

# Split project-scope config (committed with the repo) from user-scope config
# (a private repo that follows the user between machines).
setup-scopes.sh

node -e "
const fs = require('fs');
const cfgPath = process.env.HOME + '/.claude.json';
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch(e) {}
if (!cfg.projects) cfg.projects = {};
if (!cfg.projects['/workspace']) cfg.projects['/workspace'] = {};
cfg.projects['/workspace'].hasTrustDialogAccepted = true;
fs.writeFileSync(cfgPath, JSON.stringify(cfg));
"

eval "exec claude --dangerously-skip-permissions $CLAUDE_ARGS"
EOF
