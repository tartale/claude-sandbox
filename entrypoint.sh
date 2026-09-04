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

printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' > /tmp/gitconfig
if [ -n "$GITHUB_TOKEN" ]; then
    printf '#!/bin/sh\necho username=x-access-token\necho password=%s\n' "$GITHUB_TOKEN" > /tmp/git-credential-github-token
    chmod +x /tmp/git-credential-github-token
    printf '[credential "https://github.com"]\n\thelper = /tmp/git-credential-github-token\n' >> /tmp/gitconfig
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
