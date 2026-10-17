#!/usr/bin/env bash
# Sets up a project for claude-sandbox. Run on the HOST from the project root:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/init.sh)"
#
# Run with --help for what it does.
set -euo pipefail

usage() {
    cat <<'EOF2'
init.sh   (takes no options; it asks as it goes)

  - creates .claude/sandbox/{build,run,start}.sh and plugin.sh stubs (existing files are kept)
  - walks you through a single-repo fine-grained token, validates it, and writes
    CS_GITHUB_TOKEN to .env (mode 600, git-excluded); CS_ENV_FILE overrides the file
  - optionally stores a package-only ghcr.io login in ~/.docker-sandbox
  - optionally creates a "main" branch ruleset (needs gh)
EOF2
}

ENV_FILE="${CS_ENV_FILE:-.env}"
DOCKER_DIR="${CS_SANDBOX_DOCKER_CONFIG:-$HOME/.docker-sandbox}"

case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "init.sh takes no options (see --help)" >&2; exit 2 ;;
esac

# Colors only on a terminal, and never when NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi
say()  { printf '\n%s%s%s\n' "${BOLD}${CYAN}" "$*" "${RESET}"; }
ok()   { printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { printf '  %s!%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
note() { printf '  %s%s%s\n' "${DIM}" "$*" "${RESET}"; }
die()  { printf '%serror:%s %s\n' "${RED}${BOLD}" "${RESET}" "$*" >&2; exit 1; }
ask() { local a; read -r -p "$1 " a; [[ "$a" =~ ^[Yy] ]]; }
ask_yes() { local a; read -r -p "$1 " a; ! [[ "$a" =~ ^[Nn] ]]; }

# GET a GitHub API path with a token, without putting the token on a command line.
# Prints "HTTP_CODE" on the first line, then response headers, a blank line, and the body.
gh_get() {
    curl -sS -i --config <(printf 'header = "Authorization: Bearer %s"\n' "$1") \
        -H "Accept: application/vnd.github+json" "https://api.github.com$2" | tr -d '\r'
}
http_code() { sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p'; }

[ -d /workspace ] && [ -S /var/run/docker.sock ] && [ -n "${CUID:-}" ] && die "run this on the host, not inside the sandbox"

say "Prerequisites"
command -v curl >/dev/null || die "curl is required"
ok "curl"
if command -v envsubst >/dev/null; then
    ok "envsubst"
else
    warn "envsubst missing (the launcher needs it to read $ENV_FILE)"
    note "macOS:          brew install gettext && brew link --force gettext"
    note "Debian/Ubuntu:  sudo apt-get install gettext-base"
fi
if command -v gh >/dev/null; then
    ok "gh"
else
    warn "gh missing (needed for the branch ruleset)"
    note "macOS:          brew install gh"
    note "Debian/Ubuntu:  sudo apt-get install gh   (or see https://cli.github.com)"
fi

REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##') || true
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    read -r -p "  GitHub repo (OWNER/NAME): " REPO
    [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "expected OWNER/NAME"
fi
ok "repo $REPO"

# --- questions (all asked up front) ------------------------------------------
say "Questions"
DO_TOKEN=0; DO_REGISTRY=0; DO_RULESET=0
ask_yes "  Create and store a GitHub token for $REPO? [Y/n]" && DO_TOKEN=1
if ask_yes "  Store a package-only ghcr.io login for pushing images? [Y/n]"; then
    DO_REGISTRY=1
    if [ -e "$DOCKER_DIR/config.json" ] && ! ask_yes "  $DOCKER_DIR/config.json exists; replace it? [Y/n]"; then
        DO_REGISTRY=0
        note "keeping the existing registry login"
    fi
fi
HAVE_GH=0; command -v gh >/dev/null && HAVE_GH=1
GH_NOTE=""; [ "$HAVE_GH" = 1 ] || GH_NOTE=" (requires 'gh' - not installed)"
if ask_yes "  Create a 'main' ruleset on $REPO?$GH_NOTE [Y/n]"; then
    [ "$HAVE_GH" = 1 ] || die "install gh (see above), then rerun"
    gh auth status >/dev/null 2>&1 || die "run 'gh auth login' as a repo admin first"
    DO_RULESET=1
fi

# --- project stubs -----------------------------------------------------------
say "Stubs in .claude/sandbox"
IMAGE_TAG=$(printf '%s' "${REPO#*/}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_.\n-' '-')
mkdir -p .claude/sandbox
write_stub() {   # path mode, content on stdin
    if [ -e "$1" ]; then note "kept    $1"; cat >/dev/null; return; fi
    sed "s/@TAG@/$IMAGE_TAG/g" > "$1"; chmod "$2" "$1"; ok "created $1"
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
NAME="${CS_CONTAINER_NAME:-cs-@TAG@}"
export CS_CONTAINER_NAME="$NAME"

case "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true)" in
    true)  echo "$NAME is already running" ;;
    false) docker start "$NAME" >/dev/null; echo "restarted $NAME" ;;
    *)     CS_DOCKER_FLAGS="-d -t ${CS_DOCKER_FLAGS:-}" \
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

# --- launcher settings in .envrc ---------------------------------------------
# Add any CS_ launcher variable that .envrc does not mention yet, with its default;
# variables whose default is "unset" go in commented out.
say "Launcher settings in .envrc"
add_setting() {   # NAME VALUE ACTIVE(1|0) COMMENT
    if [ -f .envrc ] && grep -qE "^[[:space:]]*#?[[:space:]]*(export[[:space:]]+)?$1=" .envrc; then
        note "kept    $1"
        return
    fi
    [ -s .envrc ] && echo >> .envrc
    printf '# %s\n' "$4" >> .envrc
    if [ "$3" = 1 ]; then printf 'export %s=%s\n' "$1" "$2" >> .envrc
    else printf '# export %s=%s\n' "$1" "$2" >> .envrc; fi
    ok "added   $1"
}
add_setting CS_IMAGE_REPO ghcr.io/tartale/claude-sandbox 1 "Image repository, including registry host and namespace."
add_setting CS_IMAGE_TAG "$IMAGE_TAG" 1 "Tag of this project's sandbox image."
add_setting CS_ENV_FILE "$ENV_FILE" 1 "Env file passed into the container."
add_setting CS_DOCKER_LOGIN false 1 "true mounts your docker registry logins (read-only) into the container."
add_setting CS_USER_CONFIG "" 0 "Path to your user-config checkout (user-scope rules and memories)."
add_setting CS_DOCKER_FLAGS "" 0 "Extra docker run flags, e.g. \"-v /host/path:/container/path\"."
add_setting CS_PIDS_LIMIT "" 0 "Maximum number of processes in the container."
add_setting CS_MEMORY "" 0 "Container memory limit, e.g. 8g."
if command -v direnv >/dev/null; then note "run: direnv allow"; else note "direnv not installed; export these in your shell instead"; fi

# --- fine-grained PAT for git and gh -----------------------------------------
if [ "$DO_TOKEN" = 1 ]; then
    say "Token for $REPO"
    URL="https://github.com/settings/personal-access-tokens/new?name=cs-${REPO#*/}&description=claude-sandbox&expires_in=90&contents=write&pull_requests=write&issues=write&metadata=read"
    note "In the browser: Only select repositories -> $REPO. Keep the pre-filled"
    note "permissions (Contents, Pull requests, Issues: RW). No Administration or Workflows."
    note "$URL"
    read -r -p "  Press Enter to open it (Ctrl-C to stop)... " _
    (command -v open >/dev/null && open "$URL") || (command -v xdg-open >/dev/null && xdg-open "$URL") || warn "could not open a browser; use the link above"

    read -r -s -p "  Paste the token (hidden; blank skips): " TOKEN; echo
    if [ -n "$TOKEN" ]; then
        case "$TOKEN" in
            github_pat_*) ;;
            ghp_*) die "that is a classic token, which cannot be limited to one repo. Create a fine-grained one." ;;
            *) die "not a GitHub fine-grained token (expected github_pat_...)" ;;
        esac
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
        ok "push access, no Administration"
        # Every fine-grained token can read all public repos, so only private ones show the selection.
        U=$(gh_get "$TOKEN" "/user/repos?per_page=100&visibility=private&affiliation=owner")
        OTHERS=$(printf '%s\n' "$U" | grep -o '"full_name": *"[^"]*"' | cut -d'"' -f4 | grep -cvxF "$REPO" || true)
        if [ "$OTHERS" -gt 0 ]; then
            warn "token can also reach $OTHERS other private repo(s)"
            ask "  Continue anyway? [y/N]" || die "recreate the token with only $REPO selected"
        else
            ok "no other private repos reachable"
        fi
        note "Workflows permission cannot be probed; confirm it is off."
        ( umask 077
          touch "$ENV_FILE"
          tmp=$(mktemp)
          env_comment="# Fine-grained GitHub token, limited to $REPO (git and gh in the sandbox)."
          # Drop any earlier entry and its comment, plus trailing blank lines, then append.
          grep -vxF -e "$env_comment" "$ENV_FILE" | grep -v '^CS_GITHUB_TOKEN=' \
              | awk '{ l[NR] = $0 } /./ { n = NR } END { for (i = 1; i <= n; i++) print l[i] }' > "$tmp" || true
          [ -s "$tmp" ] && echo >> "$tmp"
          printf '%s\nCS_GITHUB_TOKEN=%s\n' "$env_comment" "$TOKEN" >> "$tmp"
          cat "$tmp" > "$ENV_FILE"; rm -f "$tmp" )
        chmod 600 "$ENV_FILE"
        if git rev-parse --git-dir >/dev/null 2>&1 && ! git check-ignore -q "$ENV_FILE"; then
            echo "$ENV_FILE" >> "$(git rev-parse --git-dir)/info/exclude"
            note "added $ENV_FILE to .git/info/exclude"
        fi
        ok "CS_GITHUB_TOKEN saved to $ENV_FILE (mode 600)"
        unset TOKEN R A U OTHERS
    else
        note "no token entered; nothing written"
    fi
fi

# --- GHCR login in a dedicated docker config ---------------------------------
if [ "$DO_REGISTRY" = 1 ]; then
    say "Registry login (ghcr.io)"
    note "Classic token, ONLY write:packages: https://github.com/settings/tokens/new?scopes=write:packages&description=cs-ghcr"
    read -r -p "  GitHub username: " GHUSER
    read -r -s -p "  Classic token (hidden): " CT; echo
    case "$CT" in ghp_*) ;; *) die "expected a classic token (ghp_...)" ;; esac
    H=$(gh_get "$CT" "/user")
    [ "$(printf '%s\n' "$H" | http_code)" = 200 ] || die "token rejected by GitHub"
    SCOPES=$(printf '%s\n' "$H" | tr 'A-Z' 'a-z' | sed -n 's/^x-oauth-scopes: *//p')
    case ",$SCOPES," in *write:packages*) ;; *) die "token lacks write:packages (has: ${SCOPES:-none})" ;; esac
    EXTRA=$(printf '%s' "$SCOPES" | tr -d ' ' | tr ',' '\n' | grep -vE '^(write:packages|read:packages)$' || true)
    [ -z "$EXTRA" ] || warn "token also has scopes: $(echo $EXTRA); only write:packages is needed"
    # Written by hand: `docker login` would hand the secret to a credential helper
    # (macOS Keychain), and the container cannot reach that.
    ( umask 077; mkdir -p "$DOCKER_DIR"
      printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$(printf '%s:%s' "$GHUSER" "$CT" | base64 | tr -d '\n')" > "$DOCKER_DIR/config.json" )
    unset CT H
    ok "stored in $DOCKER_DIR"
    note "launch with: DOCKER_CONFIG=$DOCKER_DIR CS_DOCKER_LOGIN=true claude-sandbox.sh  (shell env, not $ENV_FILE)"
    note "after the first push: package settings -> Manage Actions access -> add $REPO (Write)"
    note "Dockerfile: LABEL org.opencontainers.image.source=\"https://github.com/$REPO\" links the package to the repo"
fi

# --- branch ruleset ----------------------------------------------------------
if [ "$DO_RULESET" = 1 ]; then
    say "Branch ruleset"
    if gh api "repos/$REPO/rulesets" --jq '.[].name' | grep -qx main; then
        note "ruleset 'main' already exists; left alone"
    else
        gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null <<'JSON'
{"name":"main","target":"branch","enforcement":"active","bypass_actors":[],
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "rules":[{"type":"deletion"},{"type":"non_fast_forward"},
  {"type":"pull_request","parameters":{"required_approving_review_count":0,
   "dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,
   "require_last_push_approval":false,"required_review_thread_resolution":false}}]}
JSON
        ok "ruleset created (add required status checks once CI exists)"
    fi
fi

say "Done"
note "Start with .claude/sandbox/run.sh"
