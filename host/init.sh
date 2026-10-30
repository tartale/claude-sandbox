#!/usr/bin/env bash
# Sets up a project for claude-sandbox. Run on the HOST from the project root:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/tartale/claude-sandbox/refs/heads/main/cs)" cs init
#
# (cs init runs this script.) Run with --help for what it does.
set -euo pipefail

usage() {
    cat <<'EOF2'
cs init [--yes | --no]   (asks as it goes; --yes or --no answers the yes/no questions itself)

  - creates .claude/sandbox/{build,run,start}.sh and plugin.sh stubs (existing files are kept)
  - walks you through a single-repo fine-grained token, validates it, and writes
    CS_GITHUB_TOKEN to .env (mode 600, git-excluded); CS_ENV_FILE overrides the file
  - works with GitHub Enterprise: the host comes from the origin remote, or from
    CS_GITHUB_HOST in the environment or .env (written to .env as CS_GITHUB_HOST)
  - adds CS_USER_CONFIG_REPO (pre-filled) and CS_USER_CONFIG_TOKEN to .env, commented out
  - optionally stores a package-only ghcr.io login in ~/.docker-sandbox
  - optionally sets up the "main" branch ruleset and a ruleset for v* tags (needs gh as a repo admin);
    when the token is for a separate bot account, "main" requires your approval

  --yes   answer yes: an edited stub is replaced (after a backup) and the ruleset is created
          when that is possible; the token and registry login need a secret pasted in, so
          they are skipped
  --no    answer no to everything: edited stubs are kept, nothing is created on GitHub
EOF2
}

ENV_FILE="${CS_ENV_FILE:-.env}"
DOCKER_DIR="${CS_SANDBOX_DOCKER_CONFIG:-$HOME/.docker-sandbox}"

AUTO=""   # yes | no: answer the yes/no questions without asking
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --yes|--no)
            [ -z "$AUTO" ] || [ "$AUTO" = "${arg#--}" ] || { echo "init.sh: --yes and --no cannot be combined" >&2; exit 2; }
            AUTO="${arg#--}" ;;
        *) echo "init.sh: unknown option $arg (see --help)" >&2; exit 2 ;;
    esac
done

# Colors only on a terminal, and never when NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi
say()  { printf '\n%s%s%s\n' "${BOLD}${CYAN}" "$*" "${RESET}"; }
ok()   { printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { printf '  %s!%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
# Unified diff of an edited file against its template, indented and colored.
show_diff() {   # your-copy template
    note "- your copy   + template"
    diff -u -L "your copy" -L template "$1" "$2" | awk -v r="$RED" -v g="$GREEN" -v c="$CYAN" -v d="$DIM" -v z="$RESET" '
        /^(---|\+\+\+) / { next }
        /^@@/               { print "    " c $0 z; next }
        /^-/                { print "    " r $0 z; next }
        /^\+/               { print "    " g $0 z; next }
                            { print "    " d $0 z }' || true
}
cmd()  { printf '      %s%s%s\n' "${BOLD}" "$*" "${RESET}"; }   # a command or URL alone on its line, to copy
note() { printf '  %s%s%s\n' "${DIM}" "$*" "${RESET}"; }
die()  { printf '%serror:%s %s\n' "${RED}${BOLD}" "${RESET}" "$*" >&2; exit 1; }
# ask_def PROMPT Y|N [YES_OK] -- yes/no question; Enter picks the default, which the prompt
# shows. With --yes or --no it answers itself; YES_OK=0 marks a question --yes cannot say
# yes to (the step needs something typed in).
ask_def() {
    local a hint="[Y/n]"; [ "$2" = N ] && hint="[y/N]"
    if [ -n "$AUTO" ]; then
        if [ "$AUTO" = yes ] && [ "${3:-1}" != 0 ]; then echo "$1 $hint y (--yes)"; return 0; fi
        echo "$1 $hint n (--$AUTO)"; return 1
    fi
    read -r -p "$1 $hint " a
    if [ "$2" = N ]; then [[ "$a" =~ ^[Yy] ]]; else ! [[ "$a" =~ ^[Nn] ]]; fi
}

# GET a GitHub API path with a token, without putting the token on a command line.
# Prints "HTTP_CODE" on the first line, then response headers, a blank line, and the body.
gh_get() {
    curl -sS -i --config <(printf 'header = "Authorization: Bearer %s"\n' "$1") \
        -H "Accept: application/vnd.github+json" "$(api_base "$GITHUB_HOST")$2" | tr -d '\r'
}

# The REST API of a GitHub host: api.github.com; https://api.TENANT.ghe.com for Enterprise
# Cloud with data residency; https://HOST/api/v3 for Enterprise Server.
api_base() {
    case "$1" in
        github.com) echo https://api.github.com ;;
        *.ghe.com) echo "https://api.$1" ;;
        *) echo "https://$1/api/v3" ;;
    esac
}

# parse_remote URL -- prints "HOST PATH" for the https, ssh:// and scp-style (git@host:path) remotes.
parse_remote() {
    printf '%s\n' "$1" | sed -E \
        -e 's#^(https?|ssh)://([^@/]*@)?([^/:]+)(:[0-9]+)?/(.*)$#\3 \5#' \
        -e 't' \
        -e 's#^([^@/:]+@)?([^/:]+):([^/].*)$#\2 \3#'
}

# Checks a fine-grained token against $REPO. Prints the problem and returns 1 if it
# is unusable; otherwise returns 0.
token_problem() {
    local R A
    case "$1" in
        github_pat_*) ;;
        *) echo "not a GitHub fine-grained token (expected github_pat_...)"; return 1 ;;
    esac
    # /repos/...permissions describes YOUR role on the repo, not the token's, so
    # probe what the token itself can do instead.
    R=$(gh_get "$1" "/repos/$REPO")
    [ "$(printf '%s\n' "$R" | http_code)" = 200 ] || { echo "token cannot read $REPO (check the repository selection)"; return 1; }
    # Reading Actions settings needs the Administration permission.
    A=$(gh_get "$1" "/repos/$REPO/actions/permissions")
    [ "$(printf '%s\n' "$A" | http_code)" = 200 ] && { echo "token has the Administration permission; remove it"; return 1; }
    push_problem "$1"
}

# The receive-pack advertisement is refused unless the token may push.
push_problem() {
    local P
    P=$(curl -s -o /dev/null -w '%{http_code}' --config <(printf 'user = "x-access-token:%s"\n' "$1") \
        "https://$GITHUB_HOST/$REPO.git/info/refs?service=git-receive-pack")
    [ "$P" = 200 ] || { echo "token cannot push to $REPO (HTTP $P); give it Contents: read/write"; return 1; }
    return 0
}

# A classic token (ghp_) cannot be limited to one repo or probed for Administration, so the
# only checks are that it can read and push to $REPO.
classic_token_problem() {
    local R
    R=$(gh_get "$1" "/repos/$REPO")
    [ "$(printf '%s\n' "$R" | http_code)" = 200 ] || { echo "token cannot read $REPO"; return 1; }
    push_problem "$1"
}

# Prints the scopes a classic token carries, from the X-OAuth-Scopes header of any API call.
classic_scopes() {
    gh_get "$1" "/user" | sed -n 's/^[Xx]-[Oo][Aa][Uu][Tt][Hh]-[Ss][Cc][Oo][Pp][Ee][Ss]: *//p' | head -n 1
}

# Prints how many private repos besides $REPO the token can reach. Every fine-grained
# token can read all public repos, so only private ones show the selection.
token_other_repos() {
    gh_get "$1" "/user/repos?per_page=100&visibility=private&affiliation=owner" \
        | grep -o '"full_name": *"[^"]*"' | cut -d'"' -f4 | grep -cvxF "$REPO" || true
}

http_code() { sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p'; }

# The login of the account a token belongs to.
token_owner() { gh_get "$1" "/user" | grep -o '"login": *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

[ -d /workspace ] && [ -S /var/run/docker.sock ] && [ -n "${CUID:-}" ] && die "run this on the host, not inside the sandbox"

say "Prerequisites"
command -v curl >/dev/null || die "curl is required"
ok "curl"
if command -v envsubst >/dev/null; then
    ok "envsubst"
else
    warn "envsubst missing (the launcher needs it to read $ENV_FILE)"
    note "macOS:"
    cmd "brew install gettext && brew link --force gettext"
    note "Debian/Ubuntu:"
    cmd "sudo apt-get install gettext-base"
    die "install envsubst, then run init.sh again"
fi
if command -v gh >/dev/null; then
    ok "gh"
else
    warn "gh missing (needed for the branch ruleset)"
    note "macOS:"
    cmd "brew install gh"
    note "Debian/Ubuntu:"
    cmd "sudo apt-get install gh"
    note "other systems: https://cli.github.com"
fi

# The host and repo come from the origin remote. CS_GITHUB_HOST (environment, else .env)
# overrides the host, for a remote that goes through an alias.
REMOTE_PARTS=$(parse_remote "$(git remote get-url origin 2>/dev/null || true)")
REMOTE_HOST=${REMOTE_PARTS%% *}
REPO=""; [ -z "$REMOTE_PARTS" ] || REPO=$(printf '%s' "${REMOTE_PARTS#* }" | sed -E 's#/$##; s#\.git$##')
GITHUB_HOST="${CS_GITHUB_HOST:-}"
[ -n "$GITHUB_HOST" ] || { [ -f "$ENV_FILE" ] && GITHUB_HOST=$(grep '^CS_GITHUB_HOST=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true); } || true
[ -n "$GITHUB_HOST" ] || GITHUB_HOST=${REMOTE_HOST:-github.com}
[[ "$GITHUB_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "not a host name: $GITHUB_HOST"
export GH_HOST="$GITHUB_HOST"   # gh talks to this host
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    [ -z "$AUTO" ] || die "could not work out the GitHub repo from the origin remote; run init.sh without --$AUTO"
    read -r -p "  GitHub repo (OWNER/NAME): " REPO
    [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "expected OWNER/NAME"
fi
ok "repo $REPO on $GITHUB_HOST"

# --- stub templates, rendered to a temp dir so they can be compared ------------
IMAGE_TAG=$(printf '%s' "${REPO#*/}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_.\n-' '-')
STUB_OUT=.claude/sandbox
STUB_NAMES="build.sh run.sh start.sh restart.sh sync.sh plugin.sh"
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
render_stub() {   # name, content on stdin
    sed "s/@TAG@/$IMAGE_TAG/g; s/@REPO@/${REPO#*/}/g" > "$STUB_DIR/$1"
}
stub_mode() { if [ "$1" = plugin.sh ]; then echo 644; else echo 755; fi; }
install_stub() { cp "$STUB_DIR/$1" "$STUB_OUT/$1"; chmod "$(stub_mode "$1")" "$STUB_OUT/$1"; }
stub_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
file_hash() { if command -v sha256sum >/dev/null; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1; }
# .init-hashes holds "<name> <hash of what was last written> <hash of the template at the last run>".
# The template as of the last run, kept so a changed template can be merged into an edited stub.
can_merge() { [ -f "$STUB_OUT/.init-base/$1" ] && [ "$(recorded_field "$1" 3)" = "$(file_hash "$STUB_OUT/.init-base/$1")" ]; }
recorded_field() { awk -v n="$1" -v f="$2" '$1 == n { print $f }' "$STUB_OUT/.init-hashes" 2>/dev/null | head -n 1; }
# build.sh, run.sh, start.sh, restart.sh and sync.sh only hand the project to the cs command,
# fetched at the pinned version; what they do lives in the claude-sandbox repo (host/).
WRAPPER=$(cat <<'EOF2'
#!/usr/bin/env bash
# @DESC@
# Usage: .claude/sandbox/@NAME@ @ARGS@
set -euo pipefail

THIS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The claude-sandbox version: CS_REF (a commit, tag or branch of tartale/claude-sandbox), else
# the commit init.sh pinned in the file "ref" next to this script, else main.
# CS_REF=latest follows main.
export CS_REF="${CS_REF:-$(cat "${THIS_SCRIPT_DIR}/ref" 2>/dev/null || echo main)}"
[ "${CS_REF}" != latest ] || CS_REF=main

CS_PROJECT_DIR="$(cd "${THIS_SCRIPT_DIR}/../.." && pwd)"
export CS_PROJECT_DIR CS_PROJECT_NAME="@REPO@"
exec /bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/tartale/claude-sandbox/${CS_REF}/cs")" cs @CMD@ "$@"
EOF2
)
render_wrapper() {   # stub name, cs command, what it does, its arguments
    printf '%s\n' "$WRAPPER" | sed "s#@NAME@#$1#g; s#@CMD@#$2#g; s#@DESC@#$3#g; s#@ARGS@#$4#g" | render_stub "$1"
}
render_wrapper build.sh build "Builds this project's sandbox image from plugin.sh and pushes it." "[--no-push]"
render_wrapper run.sh run "Starts this project's sandbox interactively." "[claude args]"
render_wrapper start.sh start "Starts this project's sandbox in the background." "[claude args]"
render_wrapper restart.sh restart "Rebuilds the image and restarts this project's background sandbox." "[--no-push] [claude args]"
render_wrapper sync.sh sync "Applies the patch a sandbox session wrote with claude-user-sync." "[apply|show|status]"
render_stub plugin.sh <<'EOF2'
#!/usr/bin/env bash
# Runs as root while this project's sandbox image is built (see build.sh).
# PLUGINS_DIR points at claude-sandbox's built-in plugins.
set -euo pipefail

# Built-in plugins:
# "${PLUGINS_DIR}/languages/cpp.sh"
# "${PLUGINS_DIR}/languages/go.sh"
# "${PLUGINS_DIR}/languages/java.sh"
# "${PLUGINS_DIR}/languages/python2.sh"
# "${PLUGINS_DIR}/languages/python3.sh"
# "${PLUGINS_DIR}/languages/react.sh"
# "${PLUGINS_DIR}/languages/ruby.sh"
# "${PLUGINS_DIR}/languages/rust.sh"
# "${PLUGINS_DIR}/languages/typescript.sh"
# "${PLUGINS_DIR}/tools/docker.sh"
# "${PLUGINS_DIR}/tools/playwright.sh"

# Project-specific packages:
# apt-get update && apt-get install -y --no-install-recommends <packages>
EOF2


# --- questions (all asked up front) ------------------------------------------
say "Questions"
DO_TOKEN=0; DO_REGISTRY=0; DO_RULESET=0

# A stub that differs from the current template:
#   - exactly what this script last wrote (unedited): updated without asking,
#     since nothing of yours is lost;
#   - edited, and the template is unchanged since the last run: left alone, so
#     a file you maintain (plugin.sh) is not a prompt on every run;
#   - edited, and the template changed (or there is no record): ask. Enter shows
#     the diff first, then the question repeats with No as the default. When the
#     template text from the last run is on hand (.init-base), m merges your
#     edits into the new template.
STUB_WRITE=""
STUB_MERGE=""
for name in $STUB_NAMES; do
    dest="$STUB_OUT/$name"
    [ -e "$dest" ] || continue
    cmp -s "$STUB_DIR/$name" "$dest" && continue
    if [ "$(recorded_field "$name" 2)" = "$(file_hash "$dest")" ]; then
        STUB_WRITE="$STUB_WRITE $name"
        continue
    fi
    [ "$(recorded_field "$name" 3)" = "$(file_hash "$STUB_DIR/$name")" ] && continue
    if [ -n "$AUTO" ]; then
        echo "  $dest differs from the template and looks edited. Replace it? (--$AUTO)"
        [ "$AUTO" = yes ] && STUB_WRITE="$STUB_WRITE $name"
        continue
    fi
    shown=0; m=""; mq=""
    if can_merge "$name"; then m="/m"; mq=" or merge your edits into it"; fi
    while :; do
        if [ "$shown" = 0 ]; then hint="[y/n$m/D]"; else hint="[y/N$m/d]"; fi
        read -r -p "  $dest differs from the template and looks edited. Replace it$mq? $hint " a
        case "$a" in
            [Dd]*)  show_diff "$dest" "$STUB_DIR/$name"; shown=1 ;;
            [Mm]*)  if [ -n "$m" ]; then STUB_WRITE="$STUB_WRITE $name"; STUB_MERGE="$STUB_MERGE $name"; break; fi ;;
            [Yy]*)  STUB_WRITE="$STUB_WRITE $name"; break ;;
            [Nn]*)  break ;;
            "")     if [ "$shown" = 0 ]; then show_diff "$dest" "$STUB_DIR/$name"; shown=1; else break; fi ;;
        esac
    done
done

# Questions about things that are already set up default to No.
# The token already in the env file, and whose it is, drive the defaults of the two questions below.
STORED=""; STORED_OWNER=""; ADMIN_NOW=""
[ -f "$ENV_FILE" ] && STORED=$(grep '^CS_GITHUB_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
if [ -n "$STORED" ] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    STORED_OWNER=$(token_owner "$STORED"); ADMIN_NOW=$(gh api user --jq .login 2>/dev/null || true)
fi

# With the token on a second account, the agent cannot approve its own pull requests, so the
# ruleset can require your approval. Without one, the token acts as you and can merge freely.
# A token already stored on another account than yours means the bot is set up: default to yes, and
# to that account's name.
BOT=""; BOT_DEFAULT=N; BOT_NOTE=""; BOT_SUGGEST=""
if [ -n "$STORED_OWNER" ] && [ -n "$ADMIN_NOW" ] && [ "$(lower "$STORED_OWNER")" != "$(lower "$ADMIN_NOW")" ]; then
    BOT_DEFAULT=Y; BOT_SUGGEST=$STORED_OWNER; BOT_NOTE=" (the stored token belongs to $STORED_OWNER)"
fi
if ask_def "  Use a separate bot account for the sandbox's token (so the agent cannot approve its own PRs)?$BOT_NOTE" "$BOT_DEFAULT" 0; then
    read -r -p "  The bot's GitHub username${BOT_SUGGEST:+ [$BOT_SUGGEST]}: " BOT
    BOT=${BOT:-$BOT_SUGGEST}
    [[ "$BOT" =~ ^[A-Za-z0-9-]+$ ]] || die "not a GitHub username: ${BOT:-(none)}"
fi

# The token question comes second so its default can follow the answer: with a bot, a token that
# is not the bot's has to be replaced; without one, a token that works can stay.
TOKEN_DEFAULT=Y; TOKEN_NOTE=""
if [ -n "$BOT" ]; then
    if [ -z "$STORED" ]; then
        :
    elif [ -n "$STORED_OWNER" ] && [ "$(lower "$STORED_OWNER")" = "$(lower "$BOT")" ]; then
        TOKEN_DEFAULT=N; TOKEN_NOTE=" (the token in $ENV_FILE is $BOT's)"
    else
        TOKEN_NOTE=" (the token in $ENV_FILE belongs to ${STORED_OWNER:-an unknown account}, not $BOT)"
    fi
elif [[ "$STORED" == ghp_* ]]; then
    if classic_token_problem "$STORED" >/dev/null; then
        TOKEN_DEFAULT=N; TOKEN_NOTE=" (a classic token is already in $ENV_FILE; it reaches every repo your account can)"
    fi
elif [ -n "$STORED" ] && token_problem "$STORED" >/dev/null && [ "$(token_other_repos "$STORED")" = 0 ]; then
    TOKEN_DEFAULT=N; TOKEN_NOTE=" (a valid token is already in $ENV_FILE)"
fi
unset STORED STORED_OWNER ADMIN_NOW
ask_def "  Create and store a GitHub token for $REPO?$TOKEN_NOTE" "$TOKEN_DEFAULT" 0 && DO_TOKEN=1

REGISTRY_DEFAULT=Y; REGISTRY_NOTE=""
if grep -qs '"ghcr.io"' "$DOCKER_DIR/config.json"; then
    REGISTRY_DEFAULT=N; REGISTRY_NOTE=" (already stored in $DOCKER_DIR)"
fi
if [ "$GITHUB_HOST" != github.com ]; then
    note "no ghcr.io login: $GITHUB_HOST is not github.com (point CS_IMAGE_REPO at your registry instead)"
else
    ask_def "  Store a package-only ghcr.io login for pushing images?$REGISTRY_NOTE" "$REGISTRY_DEFAULT" 0 && DO_REGISTRY=1
fi

HAVE_GH=0; command -v gh >/dev/null && HAVE_GH=1
RULESET_DEFAULT=Y; RULESET_NOTE=""
if [ "$HAVE_GH" = 0 ]; then
    RULESET_NOTE=" (requires 'gh' - not installed)"
elif REPO_INFO=$(gh api "repos/$REPO" --jq '[.private, .permissions.admin] | @tsv' 2>/dev/null); then
    # Rulesets need admin on the repo, and private repos need a paid plan (the plan
    # itself is not reliably readable, so a private repo only gets a warning).
    if [ "${REPO_INFO##*$'\t'}" != true ]; then
        RULESET_DEFAULT=N; RULESET_NOTE=" (you are not an admin of $REPO)"
    elif [ "${REPO_INFO%%$'\t'*}" = true ]; then
        RULESET_DEFAULT=N; RULESET_NOTE=" (private repo: needs a paid GitHub plan; may fail)"
    fi
else
    RULESET_NOTE=" (could not read $REPO with gh; it may need 'gh auth login')"
fi
RULESET_YES_OK=0; [ "$HAVE_GH" = 1 ] && [ "$RULESET_DEFAULT" = Y ] && RULESET_YES_OK=1
if ask_def "  Set up the 'main' branch ruleset and the release-tag ruleset on $REPO?$RULESET_NOTE" "$RULESET_DEFAULT" "$RULESET_YES_OK"; then
    [ "$HAVE_GH" = 1 ] || die "install gh (commands above), then rerun"
    gh auth status >/dev/null 2>&1 || die $'sign in to gh as a repo admin, then rerun:\n\n      gh auth login'
    DO_RULESET=1
fi

# --- project stubs: apply the decisions made above ---------------------------
say "Stubs in .claude/sandbox"
mkdir -p "$STUB_OUT"
HASHES=""
for name in $STUB_NAMES; do
    dest="$STUB_OUT/$name"
    if [ ! -e "$dest" ]; then
        ok "created $dest"; install_stub "$name"
    elif cmp -s "$STUB_DIR/$name" "$dest"; then
        note "up to date $dest"
    elif stub_in "$name" "$STUB_WRITE"; then
        # Any file that is replaced is backed up first; the hash record is not
        # trusted to say nothing of value is lost.
        backup="$dest.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "$dest" "$backup"
        note "backup  $backup"
        if git rev-parse --git-dir >/dev/null 2>&1 && ! git check-ignore -q "$backup"; then
            echo "$STUB_OUT/*.bak.*" >> "$(git rev-parse --git-dir)/info/exclude"
        fi
        if stub_in "$name" "$STUB_MERGE"; then
            if git merge-file -p "$dest" "$STUB_OUT/.init-base/$name" "$STUB_DIR/$name" > "$STUB_DIR/$name.merged"; then
                ok "merged   $dest"
            else
                warn "merged $dest with conflicts; resolve the <<<<<<< markers"
            fi
            cat "$STUB_DIR/$name.merged" > "$dest"
        else
            ok "replaced $dest"; install_stub "$name"
        fi
    else
        note "kept    $dest"
    fi
    # Remember what was last written and the template seen, to tell a stale copy
    # from an edited one and to notice when the template itself changes.
    if cmp -s "$STUB_DIR/$name" "$dest"; then written=$(file_hash "$dest")
    else written=$(recorded_field "$name" 2); fi
    HASHES="$HASHES$name ${written:--} $(file_hash "$STUB_DIR/$name")"$'\n'
    mkdir -p "$STUB_OUT/.init-base"
    cp "$STUB_DIR/$name" "$STUB_OUT/.init-base/$name"
done
printf '%s' "$HASHES" > "$STUB_OUT/.init-hashes"

# --- launcher version -------------------------------------------------------
# The stubs fetch build-image.sh and claude-sandbox.sh at the commit named in
# .claude/sandbox/ref, so a later change to main does not run on this machine until
# init.sh is run again. CS_REF=<commit|tag|branch> chooses what to pin (default main);
# CS_REF=latest pins nothing, so the stubs follow main.
say "Launcher version"
PIN_REF="${CS_REF:-main}"
if [ "$PIN_REF" = latest ]; then
    rm -f "$STUB_OUT/ref"
    ok "no pin: the launcher follows main"
    note "to pin a commit instead, run init.sh without CS_REF=latest"
    PIN_SHA=
elif [[ "$PIN_REF" =~ ^[0-9a-f]{40}$ ]]; then
    PIN_SHA="$PIN_REF"
else
    PIN_SHA=$(git ls-remote https://github.com/tartale/claude-sandbox.git "refs/heads/$PIN_REF" "refs/tags/$PIN_REF" "refs/tags/$PIN_REF^{}" 2>/dev/null \
        | awk '/\^\{\}$/ { p = $1 } !/\^\{\}$/ && !f { f = $1 } END { print (p ? p : f) }') || PIN_SHA=
fi
if [ -n "$PIN_SHA" ]; then
    OLD_SHA=$(cat "$STUB_OUT/ref" 2>/dev/null || true)
    printf '%s\n' "$PIN_SHA" > "$STUB_OUT/ref"
    if [ "$OLD_SHA" = "$PIN_SHA" ]; then
        note "launcher stays at ${PIN_SHA:0:7} ($PIN_REF)"
    else
        ok "launcher pinned to ${PIN_SHA:0:7} ($PIN_REF)${OLD_SHA:+, was ${OLD_SHA:0:7}}"
    fi
    note "to move the pin, run init.sh again; to try a branch once: CS_REF=<branch> .claude/sandbox/run.sh"
elif [ "$PIN_REF" != latest ]; then
    warn "could not resolve $PIN_REF on GitHub; the stubs fetch main until init.sh can pin a commit"
fi

# --- entries: .envrc-cs and the env file --------------------------------------
# The claude-sandbox variables live in .envrc-cs (loaded by .envrc through source_env) and in
# one marked block of the env file, so what init.sh manages is kept apart from your own
# settings. Each is an "entry": comment lines, then the variable (or its commented-out
# form) as the last line; entries are separated by blank lines and kept in alphabetical order.
CS_RC=.envrc-cs
CS_BEGIN='# ################################## claude-sandbox: begin ###################################'
CS_END='# ################################### claude-sandbox: end ####################################'
CS_BANNER='# CS_ variables for claude-sandbox. init.sh manages this block and keeps the entries
# in alphabetical order; everything outside it is yours and is never touched.
# Passed into the container (docker --env-file). Read as data, never run as shell: $VAR and
# ${VAR} are expanded from the host environment (envsubst) and $(...) is not run.
# Settings for the launcher itself (CS_IMAGE_TAG and so on) belong in .envrc-cs.'

# cs_sort_entries -- paragraphs on stdin, sorted by variable name on stdout; a paragraph
# without a variable (a header) stays first, in its original order.
cs_sort_entries() {
    awk 'BEGIN { RS = ""; FS = "\n" }
    {
        n = split($0, line, "\n"); last = line[n]
        text = $0; gsub("\n", "\001", text)
        if (last ~ /^(# ?)?(export )?[A-Z][A-Z0-9_]*=/) {
            name = last; sub(/^(# ?)?(export )?/, "", name); sub(/=.*/, "", name)
            printf "1\t%s\t%s\n", name, text
        } else printf "0\t%06d\t%s\n", NR, text
    }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 \
       | awk '{ sub(/^[^\t]*\t[^\t]*\t/, ""); gsub("\001", "\n"); if (NR > 1) print ""; print }'
}

# cs_file_put FILE ENTRY -- add ENTRY to FILE, which init.sh owns outright.
cs_file_put() {
    local tmp; tmp=$(mktemp)
    { cat "$1" 2>/dev/null; printf '\n%s\n' "$2"; } | cs_sort_entries > "$tmp"
    cat "$tmp" > "$1"; rm -f "$tmp"
}

# cs_block_put FILE ENTRY -- add ENTRY to the claude-sandbox block of FILE (appended at the
# end when there is none); the rest of the file is written back as it was.
cs_block_put() {
    local file=$1 entry=$2 line state=before before='' block='' after='' entries tmp
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case $state in
                before) if [ "$line" = "$CS_BEGIN" ]; then state=block; else before+=$line$'\n'; fi ;;
                block)  if [ "$line" = "$CS_END" ]; then state=after; else block+=$line$'\n'; fi ;;
                after)  after+=$line$'\n' ;;
            esac
        done < "$file"
    fi
    entries=$(printf '%s\n\n%s\n' "${block#*$'\n\n'}" "$entry" | cs_sort_entries)
    tmp=$(mktemp)
    { printf '%s' "$before"
      if [ -n "$before" ] && [[ "$before" != *$'\n\n' ]]; then echo; fi
      printf '%s\n%s\n\n%s\n\n%s\n' "$CS_BEGIN" "$CS_BANNER" "$entries" "$CS_END"
      printf '%s' "$after"; } > "$tmp"
    cat "$tmp" > "$file"; rm -f "$tmp"
}

# --- launcher settings in .envrc-cs ------------------------------------------
# Add any launcher variable that .envrc-cs does not mention yet, with its default;
# variables whose default is "unset" go in commented out. .envrc loads the file.
say "Launcher settings in $CS_RC"
[ -s "$CS_RC" ] || printf '# claude-sandbox settings, loaded by .envrc (source_env %s). init.sh keeps the\n# entries in alphabetical order and adds any that are missing; your values are kept.\n' "$CS_RC" > "$CS_RC"
add_setting() {   # NAME VALUE ACTIVE(1|0) COMMENT
    if grep -qE "^[[:space:]]*#?[[:space:]]*(export[[:space:]]+)?$1=" "$CS_RC"; then
        note "kept    $1"
        return
    fi
    # The value is double-quoted, so a path with spaces survives and shellcheck (SC2086) is
    # satisfied; a caller that wants a variable expanded when the file is sourced passes it
    # with its dollar sign ($HOME/...).
    local entry value
    value=$(printf '%s' "$2" | sed 's/[\\"`]/\\&/g')
    entry=$(printf '%s\n' "$4" | sed 's/^/# /')
    if [ "$3" = 1 ]; then entry+=$(printf '\nexport %s="%s"' "$1" "$value")
    else entry+=$(printf '\n# export %s="%s"' "$1" "$value"); fi
    cs_file_put "$CS_RC" "$entry"
    ok "added   $1"
}
add_setting CLAUDE_VERSION "" 0 "build.sh: Claude Code version baked into the image. Default: latest."
add_setting CS_CONTAINER_NAME "" 0 "Container name. Default: cs-<repo-name> (run.sh appends -2, -3... while one is running); claude-sandbox.sh on its own adds a random suffix."
add_setting CS_DOCKER_CONFIG "$DOCKER_DIR" 0 "A docker config directory; its config.json (registry logins) is mounted read-only so the container's docker CLI can use them.
Off by default: anything in the container can read the credentials. Logins held in a credential helper (credsStore, e.g. macOS Keychain) are not available."
add_setting CS_DOCKER_FLAGS "" 0 "Extra docker run flags, as one string, e.g. \"-v /host/path:/container/path\".
--add-host works as in docker, including host-gateway. The container's /etc/hosts is docker's own, minus IPv6 localhost, so the host's hosts entries do not carry over.
A --restart here replaces start.sh's --restart=unless-stopped."
add_setting CS_ENV_FILE "$ENV_FILE" 1 "Env file passed into the container (docker --env-file). It is read as data and never run as shell."
add_setting CS_IMAGE_REPO ghcr.io/tartale/claude-sandbox 1 "Image repository, including registry host and namespace. build.sh and the launcher must use the same value."
add_setting CS_IMAGE_TAG "$IMAGE_TAG" 1 "Tag of this project's sandbox image: build.sh pushes it, run.sh and start.sh use it."
add_setting CS_LANGUAGE_VERSIONS "" 0 "build.sh: language version pins, space-separated <language>-<version>, e.g. \"go-1.25.10\". A plugin with no entry here installs the latest stable."
add_setting CS_MEMORY "" 0 "Memory limit for the container (docker run --memory), e.g. 8g. Unset means no limit."
add_setting CS_NPMRC "" 0 "build.sh: path to an npmrc file holding the registry's credentials, e.g. //registry.example.com/:_authToken=... .
It is mounted as a build secret, so it does not end up in the image or its history. Needs BuildKit."
add_setting CS_NPM_REGISTRY "" 0 "build.sh: npm registry URL for the image build (Claude Code and the plugins' npm packages). Default: https://registry.npmjs.org/."
add_setting CS_PIDS_LIMIT "" 0 "Maximum number of processes in the container (docker run --pids-limit). Unset means no limit."
add_setting CS_REF "" 0 "Launcher version: a commit, tag or branch of tartale/claude-sandbox. Overrides the commit init.sh pinned in .claude/sandbox/ref.
Set to latest to follow main with no pin; init.sh then writes none and removes an existing one."
add_setting CS_USER_CONFIG_CHECKOUT "\$HOME/.claude-user" 0 "Your own checkout of the user config repo on the host, where sync.sh applies the sandbox's patch. The launcher does not read it."
cs_file_put "$CS_RC" ""   # sorts what is there, so a file edited by hand is put back in order
if ! grep -qE '^[[:space:]]*source_env[[:space:]]+(\./)?\.envrc-cs[[:space:]]*$' .envrc 2>/dev/null; then
    [ -s .envrc ] && echo >> .envrc
    printf '# claude-sandbox launcher settings\nsource_env %s\n' "$CS_RC" >> .envrc
    ok "added   source_env $CS_RC to .envrc"
fi
if git rev-parse --git-dir >/dev/null 2>&1 && ! { git check-ignore -q .envrc && git check-ignore -q "$CS_RC"; }; then
    echo '.envrc*' >> "$(git rev-parse --git-dir)/info/exclude"
    note "added .envrc* to .git/info/exclude"
fi
if command -v direnv >/dev/null; then note "to load them:"; cmd "direnv allow"; else note "direnv not installed; load them in your shell with:"; cmd "source $CS_RC"; fi

# --- the bot account ----------------------------------------------------------
if [ -n "$BOT" ]; then
    say "Bot account $BOT"
    if [ "$HAVE_GH" = 1 ] && gh auth status >/dev/null 2>&1; then
        perm=$(gh api "repos/$REPO/collaborators/$BOT/permission" --jq .permission 2>/dev/null || true)
        case "$perm" in
            write|maintain) ok "$BOT can write to $REPO" ;;
            admin) warn "$BOT is an admin of $REPO: give it the Write role instead, or it can bypass the rules" ;;
            *) if ask_def "  $BOT is not a collaborator with write access. Invite it now?" Y 0; then
                   gh api -X PUT "repos/$REPO/collaborators/$BOT" -f permission=push >/dev/null \
                       && ok "invited $BOT with Write; accept the invitation as $BOT" \
                       || warn "could not invite $BOT; add it under Settings, Collaborators"
               else
                   note "add $BOT with the Write role under Settings, Collaborators"
               fi ;;
        esac
    else
        note "gh is not signed in: add $BOT with the Write role under Settings, Collaborators"
    fi
    if [ "$DO_TOKEN" != 1 ]; then
        # Keeping the token already in the env file: it has to be the bot's.
        STORED=""; [ -f "$ENV_FILE" ] && STORED=$(grep '^CS_GITHUB_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
        if [ -z "$STORED" ]; then
            note "no token is stored yet: run init.sh again and create one as $BOT"
        else
            TOKEN_OWNER=$(token_owner "$STORED")
            if [ "$(lower "$TOKEN_OWNER")" = "$(lower "$BOT")" ]; then
                ok "the stored token belongs to $BOT"
            else
                warn "the stored token belongs to ${TOKEN_OWNER:-an unknown account}, not $BOT"
                note "run init.sh again, say yes to creating a token, and create it while signed in as $BOT"
            fi
        fi
        unset STORED
    fi
fi

# --- fine-grained PAT for git and gh -----------------------------------------
if [ "$DO_TOKEN" = 1 ]; then
    say "Token for $REPO"
    if [ -n "$BOT" ]; then
        # A fine-grained token can only reach repos its own account owns (or an organization's), so
        # it cannot reach a repo the bot merely collaborates on. A classic token can, and what it
        # reaches is what the bot account can access: invite the bot only to the repos it may touch.
        CLASSIC_SCOPE=public_repo
        case "${REPO_INFO:-}" in true*) CLASSIC_SCOPE=repo ;; esac   # REPO_INFO is "private<TAB>admin"
        URL="https://$GITHUB_HOST/settings/tokens/new?scopes=$CLASSIC_SCOPE&description=claude-sandbox"
        note "GitHub's fine-grained tokens cannot reach a repo that $BOT only collaborates on, so create a"
        note "classic token as $BOT, with the scope $CLASSIC_SCOPE and nothing else (no workflow, no admin:*):"
        note "$URL"
        note "Sign in as $BOT (a private window) before opening the page: the token must be the bot's."
    else
        URL="https://$GITHUB_HOST/settings/personal-access-tokens/new?name=cs-${REPO#*/}&description=claude-sandbox&expires_in=90&contents=write&pull_requests=write&issues=write&metadata=read"
        note "In the browser: Only select repositories -> $REPO. Keep the pre-filled"
        note "permissions (Contents, Pull requests, Issues: RW). No Administration or Workflows."
        note "$URL"
        note "If a fine-grained token cannot be used, a classic token (ghp_) is accepted after a warning."
    fi
    read -r -p "  Press Enter to open it (Ctrl-C to stop)... " _
    (command -v open >/dev/null && open "$URL") || (command -v xdg-open >/dev/null && xdg-open "$URL") || warn "could not open a browser; use the link above"

    read -r -s -p "  Paste the token (hidden; blank skips): " TOKEN; echo
    # A terminal in bracketed-paste mode wraps the paste in ESC[200~ ... ESC[201~.
    TOKEN=${TOKEN//$'\e[200~'/}; TOKEN=${TOKEN//$'\e[201~'/}
    if [ -n "$TOKEN" ]; then
        if [[ "$TOKEN" == ghp_* ]]; then
            problem=$(classic_token_problem "$TOKEN") || die "$problem"
            ok "push access"
            scopes=$(classic_scopes "$TOKEN")
            if [ -n "$BOT" ]; then
                warn "classic token: it cannot be limited to one repository; it reaches every repo $BOT can access"
                note "invite $BOT only to the repos the agent may touch"
            else
                warn "classic token: it cannot be limited to one repository, so it reaches every repo your account can"
            fi
            note "scopes: ${scopes:-none reported}"
            risky=$(printf '%s\n' "$scopes" | tr -d ' ' | tr ',' '\n' | grep -E '^(admin:|delete_repo$|workflow$|delete:packages$)' | paste -sd, - || true)
            [ -z "$risky" ] || warn "it also carries powerful scopes the agent could use: $risky"
            CLASSIC_DEFAULT=N; [ -z "$BOT" ] || CLASSIC_DEFAULT=Y
            ask_def "  Use a classic token anyway?" "$CLASSIC_DEFAULT" 0 || die "create a fine-grained token limited to $REPO instead"
        else
            problem=$(token_problem "$TOKEN") || die "$problem"
            ok "push access, no Administration"
            OTHERS=$(token_other_repos "$TOKEN")
            if [ "$OTHERS" -gt 0 ]; then
                warn "token can also reach $OTHERS other private repo(s)"
                ask_def "  Continue anyway?" N || die "recreate the token with only $REPO selected"
            else
                ok "no other private repos reachable"
            fi
            note "Workflows permission cannot be probed; confirm it is off."
        fi
        TOKEN_OWNER=$(token_owner "$TOKEN")
        if [ -n "$BOT" ] && [ "$(lower "$TOKEN_OWNER")" != "$(lower "$BOT")" ]; then
            die "the token belongs to ${TOKEN_OWNER:-an unknown account}, not $BOT: sign in as $BOT, create the token there, and run init.sh again"
        fi
        ( umask 077
          touch "$ENV_FILE"
          tmp=$(mktemp)
          fine_comment="# Fine-grained GitHub token, limited to $REPO (git and gh in the sandbox). Whatever it can do, the agent can do: keep it to Contents, Pull requests and Issues write, with no Administration or Workflows."
          classic_comment="# Classic GitHub token (git and gh in the sandbox). It cannot be limited to one repo: it reaches every repo the account can, and whatever it can do, the agent can do."
          env_comment=$fine_comment; [[ "$TOKEN" != ghp_* ]] || env_comment=$classic_comment
          # Drop any earlier entry and its comment; the new one goes in the claude-sandbox block.
          { grep -vxF -e "$fine_comment" "$ENV_FILE" | grep -vxF -e "$classic_comment" | grep -v '^CS_GITHUB_TOKEN=' > "$tmp"; } || true
          cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
          cs_block_put "$ENV_FILE" "$(printf '%s\nCS_GITHUB_TOKEN=%s' "$env_comment" "$TOKEN")" )
        chmod 600 "$ENV_FILE"
        if git rev-parse --git-dir >/dev/null 2>&1 && ! git check-ignore -q "$ENV_FILE"; then
            echo "$ENV_FILE" >> "$(git rev-parse --git-dir)/info/exclude"
            note "added $ENV_FILE to .git/info/exclude"
        fi
        ok "CS_GITHUB_TOKEN saved to $ENV_FILE (mode 600)"
        unset TOKEN OTHERS scopes risky
    else
        note "no token entered; nothing written"
    fi
fi

# --- user-scope settings in the env file ------------------------------------
# The sandbox clones your user-scope rules and memories read-only from
# CS_USER_CONFIG_REPO with CS_USER_CONFIG_TOKEN. Both are optional (without them the
# session simply has no user scope), so they go in commented out; the repo is
# pre-filled with the usual name next to this project's owner.
say "User-scope settings in $ENV_FILE"
add_env_setting() {   # NAME VALUE COMMENT [ACTIVE: true to write it uncommented]
    if [ -f "$ENV_FILE" ] && grep -qE "^[[:space:]]*#?[[:space:]]*$1=" "$ENV_FILE"; then
        note "kept    $1"
        return
    fi
    local prefix="# "; [ "${4:-false}" != true ] || prefix=""
    ( umask 077
      touch "$ENV_FILE"
      cs_block_put "$ENV_FILE" "$(printf '%s\n' "$3" | sed 's/^/# /')
${prefix}$1=$2" )
    ok "added   $1"
}
add_env_setting CS_GITHUB_HOST "$GITHUB_HOST" "GitHub host for git, gh and the user-config clone in the sandbox: github.com, an Enterprise Server host name,
or an Enterprise Cloud tenant such as corp.ghe.com. init.sh reads it from the origin remote." "$([ "$GITHUB_HOST" != github.com ] && echo true || echo false)"
add_env_setting CS_USER_CONFIG_REPO "${REPO%%/*}/claude-user" "Private repo (owner/name) with your user-scope rules and memories, cloned read-only into the sandbox at start.
Optional: without it the session has no user scope. Set it together with CS_USER_CONFIG_TOKEN."
add_env_setting CS_USER_CONFIG_TOKEN "" "Fine-grained token with Contents: Read-only on that one repo. It stays in the environment so claude-user-pull can fetch later changes; it cannot push.
This file is readable inside the sandbox, so never give this token, or the project's, access to anything else.
To share one token across projects, export it once on the host and write CS_USER_CONFIG_TOKEN=\$YOUR_VARIABLE here: \$VAR is expanded from the host environment."
if grep -qxF "$CS_BEGIN" "$ENV_FILE" 2>/dev/null; then ( umask 077; cs_block_put "$ENV_FILE" "" ); fi   # sorts what is there
chmod 600 "$ENV_FILE"
if git rev-parse --git-dir >/dev/null 2>&1 && ! git check-ignore -q "$ENV_FILE"; then
    echo "$ENV_FILE" >> "$(git rev-parse --git-dir)/info/exclude"
    note "added $ENV_FILE to .git/info/exclude"
fi

# --- GHCR login in a dedicated docker config ---------------------------------
if [ "$DO_REGISTRY" = 1 ]; then
    say "Registry login (ghcr.io)"
    note "Classic token, ONLY write:packages:"
    cmd "https://github.com/settings/tokens/new?scopes=write:packages&description=cs-ghcr"
    read -r -p "  GitHub username: " GHUSER
    read -r -s -p "  Classic token (hidden): " CT; echo
    case "$CT" in ghp_*) ;; *) die "expected a classic token (ghp_...)" ;; esac
    H=$(gh_get "$CT" "/user")
    [ "$(printf '%s\n' "$H" | http_code)" = 200 ] || die "token rejected by GitHub"
    SCOPES=$(printf '%s\n' "$H" | tr 'A-Z' 'a-z' | sed -n 's/^x-oauth-scopes: *//p')
    case ",$SCOPES," in *write:packages*) ;; *) die "token lacks write:packages (has: ${SCOPES:-none})" ;; esac
    EXTRA=$(printf '%s' "$SCOPES" | tr -d ' ' | tr ',' '\n' | grep -vE '^(write:packages|read:packages)$' || true)
    [ -z "$EXTRA" ] || warn "token also has scopes: $(tr '\n' ' ' <<<"$EXTRA"); only write:packages is needed"
    # Written by hand: `docker login` would hand the secret to a credential helper
    # (macOS Keychain), and the container cannot reach that.
    ( umask 077; mkdir -p "$DOCKER_DIR"
      printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$(printf '%s:%s' "$GHUSER" "$CT" | base64 | tr -d '\n')" > "$DOCKER_DIR/config.json" )
    unset CT H
    ok "stored in $DOCKER_DIR"
    note "share it with the container: uncomment CS_DOCKER_CONFIG in .envrc-cs, or launch with (set in your shell, not $ENV_FILE):"
    cmd "CS_DOCKER_CONFIG=$DOCKER_DIR .claude/sandbox/run.sh"
    note "after the first push: package settings -> Manage Actions access -> add $REPO (Write)"
    note "to link the package to the repo, add this to the Dockerfile:"
    cmd "LABEL org.opencontainers.image.source=\"https://$GITHUB_HOST/$REPO\""
fi

# --- rulesets -----------------------------------------------------------------
# The "main" branch ruleset (a pull request is required; one approval too when the sandbox token
# belongs to a different account than yours, because that account cannot approve its own pull
# requests) and a ruleset on v* tags. An existing "main" ruleset is only ever made stricter, and
# only after you agree.
pr_params() {   # APPROVALS
    local fresh=false; [ "$1" -gt 0 ] && fresh=true
    printf '{"required_approving_review_count":%s,"dismiss_stale_reviews_on_push":%s,"require_code_owner_review":false,"require_last_push_approval":%s,"required_review_thread_resolution":false}' "$1" "$fresh" "$fresh"
}
if [ "$DO_RULESET" = 1 ]; then
    say "Rulesets"
    ADMIN_LOGIN=$(gh api user --jq .login 2>/dev/null || true)
    if [ -z "${TOKEN_OWNER:-}" ] && [ -f "$ENV_FILE" ]; then
        STORED=$(grep '^CS_GITHUB_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
        TOKEN_OWNER=""; [ -z "$STORED" ] || TOKEN_OWNER=$(token_owner "$STORED")
        unset STORED
    fi
    APPROVALS=0
    if [ -n "${TOKEN_OWNER:-}" ] && [ -n "$ADMIN_LOGIN" ] && [ "$(lower "$TOKEN_OWNER")" != "$(lower "$ADMIN_LOGIN")" ]; then APPROVALS=1; fi
    RULESETS=$(gh api "repos/$REPO/rulesets" --jq '.[] | [.id, .name] | @tsv' 2>/dev/null || true)
    MAIN_ID=$(awk -F'\t' '$2 == "main" { print $1; exit }' <<<"$RULESETS")
    TAGS_ID=$(awk -F'\t' '$2 == "release tags" { print $1; exit }' <<<"$RULESETS")

    if [ -z "$MAIN_ID" ]; then
        BODY=$(printf '{"name":"main","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":%s}]}' "$(pr_params "$APPROVALS")")
        if RULESET_ERR=$(printf '%s' "$BODY" | gh api -X POST "repos/$REPO/rulesets" --input - 2>&1 >/dev/null); then
            ok "branch ruleset created (add required status checks once CI exists)"
        else
            warn "GitHub refused to create the branch ruleset; everything else is done"
            note "$(printf '%s' "$RULESET_ERR" | head -n 2)"
        fi
    else
        CUR=$(gh api "repos/$REPO/rulesets/$MAIN_ID" --jq '.rules[] | select(.type == "pull_request") | .parameters | [.required_approving_review_count, .dismiss_stale_reviews_on_push, .require_last_push_approval] | @tsv' 2>/dev/null || true)
        IFS=$'\t' read -r CUR_N CUR_DISMISS CUR_LAST <<<"$CUR"
        if [ "$APPROVALS" -gt "${CUR_N:-0}" ] || { [ "$APPROVALS" -gt 0 ] && { [ "${CUR_DISMISS:-}" != true ] || [ "${CUR_LAST:-}" != true ]; }; }; then
            note "the 'main' ruleset requires ${CUR_N:-0} approval(s); the sandbox token belongs to ${TOKEN_OWNER}, not to you"
            note "wanted: $APPROVALS approval, dismissed when new commits are pushed, counted only after the last push"
            if ask_def "  Update the 'main' ruleset?" Y 1; then
                if gh api "repos/$REPO/rulesets/$MAIN_ID" --jq '{name,target,enforcement,bypass_actors,conditions,rules} | (.rules[] | select(.type == "pull_request") | .parameters) += {"required_approving_review_count":'"$APPROVALS"',"dismiss_stale_reviews_on_push":true,"require_last_push_approval":true}' \
                        | gh api -X PUT "repos/$REPO/rulesets/$MAIN_ID" --input - >/dev/null 2>&1; then
                    ok "'main' ruleset now requires $APPROVALS approval after the last push"
                else
                    warn "GitHub refused to update the 'main' ruleset"
                fi
            fi
        else
            note "ruleset 'main' already as strict as wanted; left alone"
        fi
    fi
    if [ "$APPROVALS" = 0 ]; then
        note "no approval is required: the sandbox token acts as you and can merge its own PRs."
        note "To require yours, run init.sh again, say the sandbox uses a separate bot account, and create its token as that account."
    fi

    if [ -z "$TAGS_ID" ]; then
        TAG_BODY='{"name":"release tags","target":"tag","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}]}'
        if RULESET_ERR=$(printf '%s' "$TAG_BODY" | gh api -X POST "repos/$REPO/rulesets" --input - 2>&1 >/dev/null); then
            ok "tag ruleset created: only repo admins can create, move or delete v* tags"
            note "check the sandbox token is bound by it: 'git push origin HEAD:refs/tags/v0.0.0-probe' must be refused (docs/security.md)"
        else
            warn "GitHub refused to create the tag ruleset"
            note "$(printf '%s' "$RULESET_ERR" | head -n 2)"
        fi
    else
        note "ruleset 'release tags' already exists; left alone"
    fi
fi

say "Done"
note "Start the sandbox with:"
cmd ".claude/sandbox/run.sh"
