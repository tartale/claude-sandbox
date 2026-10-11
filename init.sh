#!/usr/bin/env bash
# Sets up a project for claude-sandbox. Run on the HOST from the project root:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/init.sh)"
#
# Run with --help for what it does.
set -euo pipefail

usage() {
    cat <<'EOF2'
init.sh [--repo OWNER/NAME] [--registry] [--ruleset] [--env-file FILE]

Always:
  - creates .claude/sandbox/{build,run,start}.sh and plugin.sh stubs (existing files are kept)
  - checks envsubst, walks you through a single-repo fine-grained PAT, validates
    it, and writes CS_GITHUB_TOKEN to the env file (mode 600, git-excluded)
--registry  store a package-only login for ghcr.io in a DEDICATED docker config
            (~/.docker-sandbox) so CS_DOCKER_LOGIN never exposes your other logins
--ruleset   create a "main" ruleset (PR required, no force-push or deletion, no bypass)
EOF2
}

REPO=""; ENV_FILE=".env"; WITH_REGISTRY=0; WITH_RULESET=0
DOCKER_DIR="${CS_SANDBOX_DOCKER_CONFIG:-$HOME/.docker-sandbox}"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)     REPO="$2"; shift 2 ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --registry) WITH_REGISTRY=1; shift ;;
        --ruleset)  WITH_RULESET=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
ask() { local a; read -r -p "$1 " a; [[ "$a" =~ ^[Yy] ]]; }

# GET a GitHub API path with a token, without putting the token on a command line.
# Prints "HTTP_CODE" on the first line, then response headers, a blank line, and the body.
gh_get() {
    curl -sS -i --config <(printf 'header = "Authorization: Bearer %s"\n' "$1") \
        -H "Accept: application/vnd.github+json" "https://api.github.com$2" | tr -d '\r'
}
http_code() { sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p'; }

[ -d /workspace ] && [ -S /var/run/docker.sock ] && [ -n "${CUID:-}" ] && die "run this on the host, not inside the sandbox"

say "Checking prerequisites"
command -v curl >/dev/null || die "curl is required"
if command -v envsubst >/dev/null; then
    echo "envsubst: ok"
else
    echo "envsubst is missing; the sandbox launcher needs it to read $ENV_FILE. Install it:"
    echo "  macOS:          brew install gettext && brew link --force gettext"
    echo "  Debian/Ubuntu:  sudo apt-get install gettext-base"
fi

if [ -z "$REPO" ]; then
    REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##') || true
fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "could not work out OWNER/NAME; pass --repo"
echo "repo: $REPO"

# --- project stubs -----------------------------------------------------------
say "Creating .claude/sandbox stubs"
IMAGE_TAG=$(printf '%s' "${REPO#*/}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_.\n-' '-')
mkdir -p .claude/sandbox
write_stub() {   # path mode, content on stdin
    if [ -e "$1" ]; then echo "kept $1 (already exists)"; cat >/dev/null; return; fi
    sed "s/@TAG@/$IMAGE_TAG/g" > "$1"; chmod "$2" "$1"; echo "created $1"
}
write_stub .claude/sandbox/build.sh 755 <<'EOF2'
#!/usr/bin/env bash
# Builds this project's sandbox image from plugin.sh. Usage: .claude/sandbox/build.sh
# Then start it with run.sh or start.sh in this directory.
set -euo pipefail

THIS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PLUGINS="${THIS_SCRIPT_DIR}/plugin.sh"
export CS_IMAGE_TAG="${CS_IMAGE_TAG:-@TAG@}"

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/build-image.sh)"
EOF2
write_stub .claude/sandbox/run.sh 755 <<'EOF2'
#!/usr/bin/env bash
# Starts this project's sandbox interactively. Usage: .claude/sandbox/run.sh [claude args]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export CS_IMAGE_TAG="${CS_IMAGE_TAG:-@TAG@}"

exec /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/claude-sandbox.sh)" claude-sandbox "$@"
EOF2
write_stub .claude/sandbox/start.sh 755 <<'EOF2'
#!/usr/bin/env bash
# Starts this project's sandbox in the background; claude waits on a detached tty.
# Usage: .claude/sandbox/start.sh [claude args]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export CS_IMAGE_TAG="${CS_IMAGE_TAG:-@TAG@}"
NAME="${CS_CONTAINER_NAME:-claude-sandbox-$(basename "$PWD" | tr -c 'A-Za-z0-9_.\n-' '-')}"
export CS_CONTAINER_NAME="$NAME"

case "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true)" in
    true)  echo "$NAME is already running" ;;
    false) docker start "$NAME" >/dev/null; echo "restarted $NAME" ;;
    *)     DOCKER_FLAGS="-d -t ${DOCKER_FLAGS:-}" \
               /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/claude-sandbox.sh)" claude-sandbox "$@" >/dev/null
           echo "started $NAME" ;;
esac
echo "attach: docker attach $NAME   (detach with ctrl-p ctrl-q)"
echo "stop:   docker stop $NAME"
EOF2
write_stub .claude/sandbox/plugin.sh 644 <<'EOF2'
#!/usr/bin/env bash
# Runs as root while this project's sandbox image is built (see build.sh).
# PLUGINS_DIR points at claude-sandbox's built-in plugins.
set -euo pipefail

# Built-in plugins:
# "${PLUGINS_DIR}/languages/go.sh"
# "${PLUGINS_DIR}/tools/docker.sh"

# Project-specific packages:
# apt-get update && apt-get install -y --no-install-recommends <packages>
EOF2

# --- fine-grained PAT for git and gh -----------------------------------------
say "Create a fine-grained token for $REPO"
URL="https://github.com/settings/personal-access-tokens/new?name=cs-${REPO#*/}&description=claude-sandbox&expires_in=90&contents=write&pull_requests=write&issues=write&metadata=read"
cat <<EOF
GitHub cannot create tokens through its API, so do this in the browser:
  - Repository access: "Only select repositories" -> $REPO
  - Permissions: Contents RW, Pull requests RW, Issues RW (pre-filled). Leave
    Administration, Workflows and Actions off.
  - Expiration: 90 days or less.
  - Copy the token when GitHub shows it, then come back here and paste it.

Token page: $URL
EOF
read -r -p "Press Enter to open the token page in your browser (Ctrl-C to stop)... " _
(command -v open >/dev/null && open "$URL") || (command -v xdg-open >/dev/null && xdg-open "$URL") || echo "(could not open a browser; use the link above)"

read -r -s -p "Paste the token (input hidden; blank keeps the current one): " TOKEN; echo
if [ -n "$TOKEN" ]; then
    case "$TOKEN" in
        github_pat_*) ;;
        ghp_*) die "that is a classic token, which cannot be limited to one repo. Create a fine-grained one." ;;
        *) die "not a GitHub fine-grained token (expected github_pat_...)" ;;
    esac
    say "Validating"
    # /repos/...permissions describes YOUR role on the repo, not the token's, so
    # probe what the token itself can do instead.
    R=$(gh_get "$TOKEN" "/repos/$REPO")
    [ "$(printf '%s\n' "$R" | http_code)" = 200 ] || die "token cannot read $REPO (check the repository selection)"
    # Reading Actions settings needs the Administration permission.
    A=$(gh_get "$TOKEN" "/repos/$REPO/actions/permissions")
    [ "$(printf '%s\n' "$A" | http_code)" = 200 ] && die "token has the Administration permission; remove it"
    # The receive-pack advertisement is refused unless the token may push.
    P=$(curl -s -o /dev/null -w '%{http_code}' --config <(printf 'user = "x-access-token:%s"\n' "$TOKEN") \
        "https://github.com/$REPO.git/info/refs?service=git-receive-pack")
    [ "$P" = 200 ] || die "token cannot push to $REPO (HTTP $P); give it Contents: read/write"
    echo "push access: ok, administration: no"
    # Every fine-grained token can read all public repos, so only private ones show the selection.
    U=$(gh_get "$TOKEN" "/user/repos?per_page=100&visibility=private&affiliation=owner")
    OTHERS=$(printf '%s\n' "$U" | grep -o '"full_name": *"[^"]*"' | cut -d'"' -f4 | grep -cvxF "$REPO" || true)
    if [ "$OTHERS" -gt 0 ]; then
        echo "warning: this token can reach $OTHERS other private repo(s) besides $REPO."
        ask "Continue anyway? [y/N]" || die "recreate the token with only $REPO selected"
    else
        echo "other private repos reachable: none"
    fi
    echo "(Workflows permission cannot be probed; confirm it is off on the token page.)"

    say "Writing CS_GITHUB_TOKEN to $ENV_FILE"
    ( umask 077
      touch "$ENV_FILE"
      tmp=$(mktemp)
      grep -v '^CS_GITHUB_TOKEN=' "$ENV_FILE" > "$tmp" || true
      printf 'CS_GITHUB_TOKEN=%s\n' "$TOKEN" >> "$tmp"
      cat "$tmp" > "$ENV_FILE"; rm -f "$tmp" )
    chmod 600 "$ENV_FILE"
    if git rev-parse --git-dir >/dev/null 2>&1 && ! git check-ignore -q "$ENV_FILE"; then
        echo "$ENV_FILE" >> "$(git rev-parse --git-dir)/info/exclude"
        echo "added $ENV_FILE to .git/info/exclude (local only, nothing to commit)"
    fi
    unset TOKEN R A U OTHERS
else
    echo "token unchanged"
fi

# --- GHCR login in a dedicated docker config ---------------------------------
if [ "$WITH_REGISTRY" = 1 ]; then
    say "Registry login for ghcr.io (dedicated config: $DOCKER_DIR)"
    cat <<EOF
GHCR only accepts classic tokens. Create one at
  https://github.com/settings/tokens/new?scopes=write:packages&description=cs-ghcr
with ONLY the write:packages scope (it can write every package you can).
EOF
    read -r -p "GitHub username: " GHUSER
    read -r -s -p "Classic token (hidden): " CT; echo
    case "$CT" in ghp_*) ;; *) die "expected a classic token (ghp_...)" ;; esac
    H=$(gh_get "$CT" "/user")
    [ "$(printf '%s\n' "$H" | http_code)" = 200 ] || die "token rejected by GitHub"
    SCOPES=$(printf '%s\n' "$H" | tr 'A-Z' 'a-z' | sed -n 's/^x-oauth-scopes: *//p')
    case ",$SCOPES," in *write:packages*) ;; *) die "token lacks write:packages (has: ${SCOPES:-none})" ;; esac
    EXTRA=$(printf '%s' "$SCOPES" | tr -d ' ' | tr ',' '\n' | grep -vE '^(write:packages|read:packages)$' || true)
    [ -z "$EXTRA" ] || echo "warning: token also has scopes: $(echo $EXTRA); only write:packages is needed"
    if [ -e "$DOCKER_DIR/config.json" ] && ! ask "$DOCKER_DIR/config.json exists; replace it? [y/N]"; then
        die "left $DOCKER_DIR untouched"
    fi
    # Written by hand: `docker login` would hand the secret to a credential helper
    # (macOS Keychain), and the container cannot reach that.
    ( umask 077; mkdir -p "$DOCKER_DIR"
      printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$(printf '%s:%s' "$GHUSER" "$CT" | base64 | tr -d '\n')" > "$DOCKER_DIR/config.json" )
    unset CT H
    echo "stored. Launch with:"
    echo "  DOCKER_CONFIG=$DOCKER_DIR CS_DOCKER_LOGIN=true claude-sandbox.sh"
    echo "(keep these in your shell environment, not in $ENV_FILE)"
    cat <<EOF2

After the FIRST push of the image, give the repo access to the package (needed
for CI to push it with GITHUB_TOKEN, and to link the package to the repo):
  1. Open the package settings. For a personal account:
       https://github.com/users/${REPO%%/*}/packages/container/<image-name>/settings
     (for an organization use /orgs/<org>/ instead of /users/<owner>/).
  2. "Manage Actions access" -> "Add Repository" -> $REPO -> role "Write".
  3. Optional: "Change visibility" if others need to pull without logging in
     (new packages are private).
To link the package to the repo automatically on that first push, add this to
the Dockerfile:
  LABEL org.opencontainers.image.source="https://github.com/$REPO"
EOF2
fi

# --- branch ruleset ----------------------------------------------------------
if [ "$WITH_RULESET" = 1 ]; then
    say "Branch ruleset on $REPO"
    command -v gh >/dev/null || die "gh is required for --ruleset"
    gh auth status >/dev/null 2>&1 || die "run 'gh auth login' as a repo admin first"
    if gh api "repos/$REPO/rulesets" --jq '.[].name' | grep -qx main; then
        echo "a ruleset named 'main' already exists; leaving it alone"
    elif ask "Create ruleset 'main' (PR required, no force-push/deletion, no bypass)? [y/N]"; then
        gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null <<'JSON'
{"name":"main","target":"branch","enforcement":"active","bypass_actors":[],
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "rules":[{"type":"deletion"},{"type":"non_fast_forward"},
  {"type":"pull_request","parameters":{"required_approving_review_count":0,
   "dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,
   "require_last_push_approval":false,"required_review_thread_resolution":false}}]}
JSON
        echo "created. Add required status checks in Settings -> Rules once CI exists."
    fi
fi

say "Done"
echo "Start the sandbox from the project root as usual."
