#!/usr/bin/env bash
# Tests for init.sh: the stubs it generates and how it treats files you edited.
# curl, gh and docker are absent from the test PATH and envsubst is a stand-in, so
# nothing here touches the network; every question about a token, registry login or
# ruleset is answered "n".
# shellcheck disable=SC2016  # literal $ in fixtures
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'find "${WORK}" -delete' EXIT

BIN="${WORK}/bin"
mkdir -p "${BIN}" "${WORK}/home" "${WORK}/proj"
for f in /usr/bin/* /bin/*; do
    case "${f##*/}" in envsubst|gh|curl|docker|direnv|open|xdg-open) continue ;; esac
    ln -sf "$f" "${BIN}/${f##*/}" 2>/dev/null || true
done
printf '#!/bin/sh\nexit 0\n' > "${BIN}/curl"
printf '#!/bin/sh\ncat\n' > "${BIN}/envsubst"
chmod +x "${BIN}/curl" "${BIN}/envsubst"

# A copy of init.sh whose templates differ from the real ones, to stand in for
# "the template changed since the last run".
sed 's|^set -euo pipefail$|set -euo pipefail\n# new header line|' "${ROOT}/host/init.sh" > "${WORK}/init-changed.sh"
sed 's|^set -euo pipefail$|set -euo pipefail\n# conflicting header|' "${ROOT}/host/init.sh" > "${WORK}/init-conflict.sh"

PASS=0
FAIL=0
OUT=""
pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "${OUT}" | sed 's/^/       /'; }
check() { local name=$1; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
mentions() { grep -qF -- "$1" <<<"${OUT}"; }
lacks() { ! mentions "$1"; }

STUBS="build.sh run.sh start.sh restart.sh sync.sh plugin.sh"
SB="${WORK}/proj/.claude/sandbox"

new_project() {
    find "${WORK}/proj" -mindepth 1 -delete
    find "${WORK}/home" -mindepth 1 -delete
    git -C "${WORK}/proj" init -q
    git -C "${WORK}/proj" remote add origin git@github.com:o/Demo-App.git
}

# run_init INPUT [SCRIPT] -- run init.sh in the scratch project on a pty, feeding
# INPUT (printf format) as the answers. Output lands in $OUT; init's exit status is returned.
INIT_ENV=()   # extra NAME=value pairs for the environment of the next run_init
run_init() {
    local rc
    OUT=$(cd "${WORK}/proj" && printf "$1" | env -i PATH="${BIN}" HOME="${WORK}/home" NO_COLOR=1 ${INIT_ENV[@]+"${INIT_ENV[@]}"} \
        script -qec "bash ${2:-${ROOT}/host/init.sh}" /dev/null 2>&1 | tr -d '\r')
    rc=${PIPESTATUS[0]}
    return "${rc}"
}
NO3='n\nn\nn\nn\n'   # token, bot account, registry login, ruleset

has_file() { [ -f "$1" ]; }
mode_is() { [ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" = "$2" ]; }
backups() { find "${SB}" -name "$1.bak.*" | wc -l | tr -d ' '; }
contains() { grep -qF -- "$2" "$1"; }
absent() { ! contains "$@"; }

# --- a fresh project --------------------------------------------------------
new_project
run_init "${NO3}"; rc=$?
check "a fresh project runs to the end" test "${rc}" -eq 0
for s in ${STUBS}; do check "creates ${s}" has_file "${SB}/${s}"; done
for s in build.sh run.sh start.sh restart.sh sync.sh; do check "${s} is executable" mode_is "${SB}/${s}" 755; done
check "plugin.sh is not executable" mode_is "${SB}/plugin.sh" 644
# Everything init writes that the shell reads is checked for unquoted expansions (SC2086).
if command -v shellcheck >/dev/null; then
    check "the generated stubs have no unquoted expansions" shellcheck -s bash --severity=info --include=SC2086 "${SB}"/*.sh
else
    echo "skip - the generated stubs have no unquoted expansions (shellcheck not installed)"
fi
check "stubs hand the repo name to cs" contains "${SB}/build.sh" 'CS_PROJECT_NAME="Demo-App"'
check "build.sh passes its arguments on to cs build" contains "${SB}/build.sh" '/cs")" cs build "$@"'
check "records the stub hashes" has_file "${SB}/.init-hashes"
for s in ${STUBS}; do check "keeps a copy of the ${s} template" has_file "${SB}/.init-base/${s}"; done

# plugin.sh lists every built-in plugin, commented out
builtin=$(find "${ROOT}/plugins/languages" "${ROOT}/plugins/tools" -name '*.sh' | wc -l | tr -d ' ')
listed=$(grep -c '^# "${PLUGINS_DIR}/' "${SB}/plugin.sh")
check "plugin.sh lists all ${builtin} built-in plugins" test "${listed}" -eq "${builtin}"
for p in "${ROOT}"/plugins/languages/*.sh "${ROOT}"/plugins/tools/*.sh; do
    rel=${p#"${ROOT}"/plugins/}
    check "plugin.sh lists ${rel}" contains "${SB}/plugin.sh" "${rel}"
done

# --- running again changes nothing ------------------------------------------
run_init "${NO3}"; rc=$?
check "a second run succeeds" test "${rc}" -eq 0
check "a second run finds the stubs up to date" mentions "up to date ${SB##"${WORK}"/proj/}/build.sh"
check "a second run asks nothing about stubs" lacks "looks edited"
check "a second run makes no backups" test "$(backups plugin.sh)" -eq 0

# --- an unedited stub follows the template ----------------------------------
run_init "${NO3}" "${WORK}/init-changed.sh"
check "an unedited stub is updated without a question" lacks "looks edited"
check "the updated stub has the new template text" contains "${SB}/build.sh" '# new header line'
check "an updated stub is backed up first" test "$(backups build.sh)" -eq 1

# --- an edited stub ---------------------------------------------------------
# A fresh project whose plugin.sh carries an edit. Answering a prompt records the
# new template, so each scenario starts from here.
edited_project() {
    new_project; run_init "${NO3}" >/dev/null
    echo "apt-get install -y mypkg" >> "${SB}/plugin.sh"
}

edited_project
run_init "${NO3}"
check "an edited stub with an unchanged template is left alone" contains "${SB}/plugin.sh" 'mypkg'
check "...without a question" lacks "looks edited"
check "...reported as kept" mentions "kept"

edited_project
run_init "n\n${NO3}" "${WORK}/init-changed.sh"
check "a changed template asks about an edited stub" mentions "looks edited"
check "the first prompt makes the diff the default" mentions "/D]"
check "n keeps the edited stub" contains "${SB}/plugin.sh" 'mypkg'
check "n makes no backup" test "$(backups plugin.sh)" -eq 0

edited_project
run_init "\n\n${NO3}" "${WORK}/init-changed.sh"
check "Enter shows the diff" mentions '+# new header line'
check "after the diff the default is no" mentions "[y/N/m/d]"
check "...and Enter then keeps the stub" contains "${SB}/plugin.sh" 'mypkg'

edited_project
run_init "y\n${NO3}" "${WORK}/init-changed.sh"
check "y replaces the stub" contains "${SB}/plugin.sh" '# new header line'
check "...dropping the edit" absent "${SB}/plugin.sh" 'mypkg'
check "y backs the edited stub up" test "$(backups plugin.sh)" -eq 1
check "the backup holds the edit" contains "$(find "${SB}" -name 'plugin.sh.bak.*' | head -n 1)" 'mypkg'
check "backups are git-excluded" git -C "${WORK}/proj" check-ignore -q "${SB}/plugin.sh.bak.1"

# --- merging ----------------------------------------------------------------
edited_project
run_init "m\n${NO3}" "${WORK}/init-changed.sh"
check "m is offered when the previous template is on hand" mentions "[y/n/m/D]"
check "m keeps your edit" contains "${SB}/plugin.sh" 'mypkg'
check "m brings in the template change" contains "${SB}/plugin.sh" '# new header line'
check "m leaves no conflict markers" absent "${SB}/plugin.sh" '<<<<<<<'
check "m backs the edited stub up" test "$(backups plugin.sh)" -eq 1

new_project; run_init "${NO3}" >/dev/null
sed -i.orig 's|^set -euo pipefail$|set -euo pipefail\n# my own header|' "${SB}/plugin.sh"
run_init "m\n${NO3}" "${WORK}/init-conflict.sh"
check "overlapping edits leave conflict markers" contains "${SB}/plugin.sh" '<<<<<<<'
check "...and a warning" mentions "with conflicts"

# without the kept template there is nothing to merge against
edited_project
find "${SB}/.init-base" -mindepth 1 -delete
run_init "n\n${NO3}" "${WORK}/init-changed.sh"
check "m is not offered without the previous template" lacks "m/D"

# --- launcher settings in .envrc-cs ------------------------------------------
new_project
printf 'export MINE=1\n' > "${WORK}/proj/.envrc"
run_init "${NO3}"
RC="${WORK}/proj/.envrc-cs"
names() { grep -oE '^(# )?(export )?[A-Z][A-Z0-9_]*=' "$1" | sed -E 's/^(# )?(export )?//; s/=$//'; }
if command -v shellcheck >/dev/null; then
    check ".envrc-cs and .envrc have no unquoted expansions" shellcheck -s bash --severity=info --include=SC2086 "${RC}" "${WORK}/proj/.envrc"
fi
check "values are double-quoted, including the \${HOME} default" contains "${RC}" '# export CS_USER_CONFIG_CHECKOUT="${HOME}/.claude-user"'
check "the settings go in .envrc-cs" contains "${RC}" 'export CS_IMAGE_REPO="ghcr.io/tartale/claude-sandbox"'
check ".envrc-cs comments every variable directly above it" test "$(awk '/^(# )?(export )?[A-Z_]+=/ && prev ~ /^# [A-Za-z-]/ { n++ } { prev = $0 } END { print n + 0 }' "${RC}")" -eq "$(grep -cE '^(# )?(export )?[A-Z_]+=' "${RC}")"
# The name is CS_LANGUAGE_VERSIONS everywhere; the bare name is not read or written anywhere.
# Tracked files only in a checkout, so a stale ignored file (plugins/.build, .env) cannot fail it.
old_name_hits() {
    if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "${ROOT}" grep -nE '(^|[^A-Za-z_])LANGUAGE_VERSIONS' -- . ':!tests'
    else
        grep -rnE '(^|[^A-Za-z_])LANGUAGE_VERSIONS' "${ROOT}" --exclude-dir=tests
    fi
}
check "no file mentions the old LANGUAGE_VERSIONS name" test -z "$(old_name_hits)"
# The settings init.sh adds are listed in alphabetical (byte) order in its source.
SETTING_NAMES=$(grep -oE '^add_setting [A-Z_]+' "${ROOT}/host/init.sh" | cut -d' ' -f2)
check "init.sh lists the .envrc-cs settings alphabetically" test "${SETTING_NAMES}" = "$(printf '%s\n' "${SETTING_NAMES}" | LC_ALL=C sort)"
check ".envrc-cs documents the build and sync variables" test "$(grep -cE '^# export (CS_LANGUAGE_VERSIONS|CLAUDE_VERSION|CS_CONTAINER_NAME|CS_NPM_REGISTRY|CS_NPMRC|CS_REF|CS_USER_CONFIG_CHECKOUT)=' "${RC}")" -eq 7
check ".envrc-cs lists its variables in alphabetical order" test "$(names "${RC}")" = "$(names "${RC}" | LC_ALL=C sort)"
check ".envrc gets no variables" absent "${WORK}/proj/.envrc" 'CS_IMAGE_REPO'
check ".envrc loads .envrc-cs" contains "${WORK}/proj/.envrc" 'source_env .envrc-cs'
check "...keeping what was in .envrc" contains "${WORK}/proj/.envrc" 'export MINE=1'
run_init "${NO3}"
check ".envrc loads .envrc-cs only once" test "$(grep -c '^source_env .envrc-cs' "${WORK}/proj/.envrc")" -eq 1
sed -i.bak 's/^export CS_IMAGE_TAG=.*/export CS_IMAGE_TAG=mine/' "${RC}"; rm -f "${RC}.bak"
cp "${RC}" "${WORK}/rc.before"
run_init "${NO3}"
check "a value you set in .envrc-cs is kept" contains "${RC}" 'export CS_IMAGE_TAG=mine'
check "...and the file is unchanged by another run" cmp -s "${RC}" "${WORK}/rc.before"
{ cat "${RC}"; printf '\n# Zzz.\nexport ZZZ=1\n\n# Aaa.\nexport AAA=1\n'; } > "${WORK}/rc.unsorted"; cp "${WORK}/rc.unsorted" "${RC}"
run_init "${NO3}"
check "a later run puts the entries back in order" test "$(names "${RC}")" = "$(names "${RC}" | LC_ALL=C sort)"
check "...without losing any" contains "${RC}" 'export ZZZ=1'

# --- user-scope settings in .env ----------------------------------------------
new_project
run_init "${NO3}"
ENVF="${WORK}/proj/.env"
check "adds the user-config repo, commented out, pre-filled from the owner" contains "${ENVF}" '# CS_USER_CONFIG_REPO=o/claude-user'
check "adds the user-config token, commented out and empty" contains "${ENVF}" '# CS_USER_CONFIG_TOKEN='
check "puts a comment directly above each" test "$(awk '/^# CS_USER_CONFIG_(REPO|TOKEN)=/ && prev ~ /^# [A-Z].*\.$/ { n++ } { prev = $0 } END { print n + 0 }' "${ENVF}")" -eq 2
check "the token comment says how to share it across projects" contains "${ENVF}" 'To share one token across projects'
check "the entries sit in a marked block" test "$(grep -cE 'claude-sandbox: (begin|end) #' "${ENVF}")" -eq 2
check "the block says how the file is read" contains "${ENVF}" 'Read as data, never run as shell'
check ".env is mode 600" mode_is "${ENVF}" 600
check ".env is git-excluded" contains "${WORK}/proj/.git/info/exclude" '.env'
check ".envrc is git-excluded" git -C "${WORK}/proj" check-ignore -q .envrc
check ".envrc-cs is git-excluded" git -C "${WORK}/proj" check-ignore -q .envrc-cs
BEGIN=$(grep 'claude-sandbox: begin' "${ENVF}"); END=$(grep 'claude-sandbox: end' "${ENVF}")

printf 'MY_KEY=abc\n# my note\nOTHER=1\n' > "${ENVF}"
run_init "${NO3}"
check "an existing .env keeps its content as written" test "$(head -n 3 "${ENVF}")" = "$(printf 'MY_KEY=abc\n# my note\nOTHER=1')"
check "...with the block after it, set off by a blank line" test "$(sed -n 4p "${ENVF}")" = "" -a "$(sed -n 5p "${ENVF}")" = "${BEGIN}"
cp "${ENVF}" "${WORK}/env.before"
run_init "${NO3}"
check "...and another run leaves the file unchanged" cmp -s "${ENVF}" "${WORK}/env.before"

printf 'MINE=1\n\n%s\n# banner\n\n# Z.\nCS_USER_CONFIG_TOKEN=x\n\n# A.\nCS_GITHUB_TOKEN=y\n\n%s\ntail=1\n' "${BEGIN}" "${END}" > "${ENVF}"
run_init "${NO3}"
check "entries already in the block are kept and put in order" test "$(names "${ENVF}" | tr '\n' ' ')" = "MINE CS_GITHUB_HOST CS_GITHUB_TOKEN CS_USER_CONFIG_REPO CS_USER_CONFIG_TOKEN "
check "...with the lines around the block untouched" test "$(head -n 1 "${ENVF}")" = "MINE=1" -a "$(tail -n 1 "${ENVF}")" = "tail=1"
check "...and a value in the block kept" contains "${ENVF}" 'CS_USER_CONFIG_TOKEN=x'

printf 'CS_USER_CONFIG_REPO=me/mine\n' > "${ENVF}"
run_init "${NO3}"
check "an existing repo setting is kept" contains "${ENVF}" 'CS_USER_CONFIG_REPO=me/mine'
check "...and not repeated" test "$(grep -cE '^#? ?CS_USER_CONFIG_REPO=' "${ENVF}")" -eq 1
check "...while the missing token is added" contains "${ENVF}" '# CS_USER_CONFIG_TOKEN='

# --- restart.sh: build, stop, start with the old arguments ------------------
new_project
run_init "${NO3}"
RS="${WORK}/restart"
mkdir -p "${RS}/host" "${RS}/bin"
cp "${ROOT}/host/restart.sh" "${ROOT}/host/lib.sh" "${RS}/host/"
printf '#!/bin/sh\necho "build${*:+ $*}" >> "%s/log"\n' "${RS}" > "${RS}/host/build.sh"
printf '#!/bin/sh\necho "start $*" >> "%s/log"\n' "${RS}" > "${RS}/host/start.sh"
printf '#!/bin/sh\ncase "$1" in\n  inspect) printf "%%s\\n" --name demo-app --continue "two words"; echo ;;\n  stop) echo "stop $2" >> "%s/log" ;;\nesac\n' "${RS}" > "${RS}/bin/docker"
chmod +x "${RS}"/host/*.sh "${RS}/bin/docker"
restart() { OUT=$(env -i PATH="${RS}/bin:${BIN}" CS_PROJECT_DIR="${RS}" CS_PROJECT_NAME=Demo-App bash "${RS}/host/restart.sh" "$@" 2>&1); }
: > "${RS}/log"; restart
check "restart builds, stops, then starts" test "$(tr '\n' '|' < "${RS}/log")" = "build|stop cs-demo-app|start --continue two words|"
: > "${RS}/log"; restart --resume
check "explicit arguments replace the old ones" contains "${RS}/log" 'start --resume'
: > "${RS}/log"; restart --no-push
check "--no-push goes to the build only, and the old claude arguments are still reused" test "$(tr '\n' '|' < "${RS}/log")" = "build --no-push|stop cs-demo-app|start --continue two words|"
: > "${RS}/log"; restart --no-push --resume
check "--no-push with claude arguments builds without pushing and starts with them" test "$(tr '\n' '|' < "${RS}/log")" = "build --no-push|stop cs-demo-app|start --resume|"

# --- GitHub Enterprise hosts --------------------------------------------------
RCURL="${WORK}/curl.log"
api_base() { bash -c 'source <(sed -n "/^api_base() {/,/^}/p" "$1"); api_base "$2"' _ "${ROOT}/host/init.sh" "$1"; }
check "api.github.com for github.com" test "$(api_base github.com)" = https://api.github.com
check "api.TENANT.ghe.com for a data-residency tenant" test "$(api_base corp.ghe.com)" = https://api.corp.ghe.com
check "HOST/api/v3 for Enterprise Server" test "$(api_base git.corp.example)" = https://git.corp.example/api/v3

ghe_project() {   # REMOTE
    new_project
    git -C "${WORK}/proj" remote set-url origin "$1"
}
for remote in git@git.corp.example:o/Demo-App.git https://git.corp.example/o/Demo-App.git ssh://git@git.corp.example:2222/o/Demo-App.git; do
    ghe_project "${remote}"
    run_init 'n\nn\nn\n'; rc=$?
    check "${remote}: runs to the end" test "${rc}" -eq 0
    check "${remote}: finds the repo on the Enterprise host" mentions "repo o/Demo-App on git.corp.example"
    check "${remote}: writes the host to the env file, uncommented" contains "${WORK}/proj/.env" $'\nCS_GITHUB_HOST=git.corp.example'
    check "${remote}: has no ghcr.io question" lacks "ghcr.io login for pushing"
done
ghe_project git@git.corp.example:o/Demo-App.git
run_init 'n\ny\nn\n\n\n'
check "the token page is the Enterprise host's" mentions "https://git.corp.example/settings/personal-access-tokens/new"
# A curl that logs its URLs and answers like a repo the token can read and push to, without Administration.
cat > "${BIN}/curl" <<EOS
#!/bin/bash
echo "\$@" >> "${RCURL}"
case "\$*" in
    *actions/permissions*) printf 'HTTP/2 404\r\n\r\n{}' ;;
    *info/refs*) printf 200 ;;
    *api*) printf 'HTTP/2 200\r\n\r\n[]' ;;
esac
EOS
chmod +x "${BIN}/curl"
for remote in "git@git.corp.example:o/Demo-App.git|https://git.corp.example/api/v3/repos/o/Demo-App" "git@corp.ghe.com:o/Demo-App.git|https://api.corp.ghe.com/repos/o/Demo-App"; do
    ghe_project "${remote%%|*}"; : > "${RCURL}"
    run_init 'n\ny\nn\n\ngithub_pat_x\n'
    check "${remote%%|*}: the token is checked against ${remote##*|}" contains "${RCURL}" "${remote##*|}"
    check "${remote%%|*}: push access is probed on the Enterprise host" contains "${RCURL}" "https://$(printf '%s' "${remote%%|*}" | sed -E 's#^git@([^:]+):.*#\1#')/o/Demo-App.git/info/refs"
done
printf '#!/bin/sh\nexit 0\n' > "${BIN}/curl"

new_project
run_init "${NO3}"
check "github.com: the host is documented but left commented out" contains "${WORK}/proj/.env" '# CS_GITHUB_HOST=github.com'
check "github.com: the ghcr.io question is still asked" mentions "ghcr.io login for pushing"

ghe_project git@github.com:o/Demo-App.git
printf '# x\nCS_GITHUB_HOST=git.corp.example\n' > "${WORK}/proj/.env"
run_init 'n\ny\nn\n\n\n'
check "CS_GITHUB_HOST in .env overrides the remote's host" mentions "https://git.corp.example/settings/personal-access-tokens/new"

# --- bot account, branch ruleset and tag ruleset ---------------------------------
GHD="${WORK}/gh"; mkdir -p "${GHD}"
gh_world() {   # ADMIN RULESETS(tsv, \n-separated) PR(tsv of the main ruleset's approvals/dismiss/last-push) BOT_PERMISSION
    find "${GHD}" -mindepth 1 -delete
    printf '%s\n' "$1" > "${GHD}/admin"; printf "$2" > "${GHD}/rulesets"; printf "$3" > "${GHD}/pr"; printf '%s' "$4" > "${GHD}/perm"
    cat > "${BIN}/gh" <<EOS
#!/bin/bash
D="${GHD}"
echo "gh \$*" >> "\$D/log"
case "\$*" in
    "auth status"*) exit 0 ;;
    "api user --jq .login") cat "\$D/admin" ;;
    "api user --jq .id") echo 101 ;;
    "api repos/o/Demo-App --jq .owner.type") cat "\$D/ownertype" 2>/dev/null || echo User ;;
    "api repos/o/Demo-App --jq "*) printf '%s\ttrue\n' "\$(cat "\$D/private" 2>/dev/null || echo false)" ;;
    "api repos/o/Demo-App/rulesets --jq "*) cat "\$D/rulesets" ;;
    "api repos/o/Demo-App/rulesets/7 --jq "*"@tsv") cat "\$D/pr" ;;
    "api repos/o/Demo-App/rulesets/8 --jq "*"length") cat "\$D/tagbypass" 2>/dev/null || echo 1 ;;
    "api repos/o/Demo-App/rulesets/8 --jq "*) echo '{"updated":"tags"}' ;;
    "api -X PUT repos/o/Demo-App/rulesets/8 --input - --jq "*) cat > "\$D/put8"; cat "\$D/putbypass" 2>/dev/null || echo 1 ;;
    "api repos/o/Demo-App/rulesets/7 --jq "*) echo '{"updated":"payload"}' ;;
    "api -X POST repos/o/Demo-App/rulesets --input -") cat > "\$D/post-\$(ls "\$D" | grep -c '^post-')" ;;
    "api -X POST repos/o/Demo-App/rulesets --input - --jq "*) cat > "\$D/post-\$(ls "\$D" | grep -c '^post-')"; cat "\$D/bypass" 2>/dev/null ;;
    "api -X PUT repos/o/Demo-App/rulesets/7 --input -") cat > "\$D/put" ;;
    "api repos/o/Demo-App/collaborators/"*"/permission --jq .permission") [ -s "\$D/perm" ] && cat "\$D/perm" || exit 1 ;;
esac
exit 0
EOS
    chmod +x "${BIN}/gh"
}
owner_curl() {   # LOGIN [SCOPES] -- a curl whose token belongs to LOGIN, has SCOPES (classic) and can read, push and not administer
    cat > "${BIN}/curl" <<EOS
#!/bin/bash
case "\$*" in
    *info/refs*) printf 200 ;;
    *actions/permissions*) printf 'HTTP/2 404\r\n\r\n{}' ;;
    *user/repos*) printf 'HTTP/2 200\r\n\r\n[]' ;;
    */user*) printf 'HTTP/2 200\r\nX-OAuth-Scopes: ${2:-public_repo}\r\n\r\n{"login":"$1"}' ;;
    *api*) printf 'HTTP/2 200\r\n\r\n{}' ;;
esac
EOS
    chmod +x "${BIN}/curl"
}
posts() { cat "${GHD}"/post-* 2>/dev/null; }
ghlogged() { grep -qF -- "$1" "${GHD}/log"; }
nothing_posted() { ! ls "${GHD}"/post-* >/dev/null 2>&1; }
has_posted() { posts | grep -qF -- "$1"; }

gh_world tartale '' '' ''; new_project
run_init 'n\nn\nn\ny\n'; rc=$?
check "the rulesets step creates the main ruleset" has_posted '"name":"main"'
check "...requiring a pull request but no approval when there is no bot" has_posted '"required_approving_review_count":0'
check "...and says the token can merge its own PRs" mentions "can merge its own PRs"
check "it also creates the tag ruleset" has_posted '"name":"release tags","target":"tag"'
check "...for v* tags, with the admin role able to bypass" has_posted '"include":["refs/tags/v*"]'
check "...blocking creation, update and deletion" has_posted '{"type":"creation"},{"type":"update"},{"type":"deletion"}'

gh_world tartale '' '' ''; printf '0' > "${GHD}/bypass"; new_project
run_init 'n\nn\nn\ny\n'
check "when GitHub stores no bypass for the tag ruleset, init says nobody can tag" mentions "nobody can create a v* tag"
check "...and how to release anyway" mentions "disable the 'release tags' ruleset"
gh_world tartale '' '' ''; printf '1' > "${GHD}/bypass"; new_project
run_init 'n\nn\nn\ny\n'
check "when GitHub stores a bypass, init says you can still tag" mentions "tartale can still create, move or delete v* tags"
check "...without the no-bypass note" lacks "nobody can create a v* tag"

gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
run_init 'y\ntartalebot\ny\nn\ny\nn\n\ngithub_pat_x\n'; rc=$?
check "a bot token is accepted when it belongs to the bot" test "${rc}" -eq 0
check "...stored in the env file" contains "${WORK}/proj/.env" 'CS_GITHUB_TOKEN=github_pat_x'
check "a collaborator with write access is not invited again" lacks "Invite it now"
check "with the token on another account the main ruleset requires an approval" has_posted '"required_approving_review_count":1'
check "...that counts only after the last push" has_posted '"require_last_push_approval":true'
check "...and is dismissed when new commits arrive" has_posted '"dismiss_stale_reviews_on_push":true'
check "the bot flow does not say the token can merge freely" lacks "can merge its own PRs"

gh_world tartale '' '' ''; owner_curl tartalebot; new_project
run_init 'y\ntartalebot\ny\nn\nn\ny\nn\n\ngithub_pat_x\n'
check "a bot that is not a collaborator can be invited with Write" ghlogged "api -X PUT repos/o/Demo-App/collaborators/tartalebot -f permission=push"

gh_world tartale '' '' 'admin'; owner_curl tartalebot; new_project
run_init 'y\ntartalebot\ny\nn\nn\nn\n\ngithub_pat_x\n'
check "a bot with the admin role is warned about" mentions "give it the Write role instead"

gh_world tartale '' '' 'write'; owner_curl tartale; new_project
run_init 'y\ntartalebot\ny\nn\nn\nn\n\ngithub_pat_x\n'; rc=$?
check "a token on the wrong account is refused" test "${rc}" -ne 0
check "...naming both accounts" mentions "belongs to tartale, not tartalebot"
check "...and not stored" test ! -f "${WORK}/proj/.env" -o "$(grep -c 'CS_GITHUB_TOKEN=github_pat_x' "${WORK}/proj/.env" 2>/dev/null)" = 0

# The bot question comes first so the token question's default can follow the answer.
gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init 'y\ntartalebot\n\nn\nn\n'
check "with a bot, a stored token that is the bot's is kept by default" mentions "(the token in .env is tartalebot's)"
check "...so no token step runs on Enter" lacks "Token for o/Demo-App"

gh_world tartale '' '' 'write'; owner_curl tartale; new_project
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init 'y\ntartalebot\n\nn\nn\nn\n\ngithub_pat_x\n'
check "with a bot, a stored token on another account says so" mentions "(the token in .env belongs to tartale, not tartalebot)"
check "...and Enter creates a new one" mentions "Token for o/Demo-App"

gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
run_init 'y\ntartalebot\n\nn\nn\n\n\n'
check "with a bot and no stored token the token question defaults to yes" mentions "Token for o/Demo-App"

# A bot's token is a classic one: a fine-grained token cannot reach a repo the bot only collaborates on.
gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
run_init 'y\ntartalebot\ny\nn\ny\nn\n\nghp_abc\n'; rc=$?
check "for a bot the token page is the classic one with the narrowest scope" mentions "settings/tokens/new?scopes=public_repo"
check "...named after the repository, like the fine-grained one" mentions "description=cs-Demo-App"
check "...explaining why a fine-grained token will not do" mentions "cannot reach a repo that tartalebot only collaborates on"
check "...saying what the token reaches, on the token page's instructions" mentions "invite tartalebot only to the repos the agent may touch"
check "a bot has no choice, so there is no classic-token warning" lacks "classic token: it cannot be limited"
check "...and no confirmation to answer" lacks "Use a classic token anyway"
check "...but the scopes are still shown" mentions "scopes: public_repo"
check "...and the token is stored" contains "${WORK}/proj/.env" 'CS_GITHUB_TOKEN=ghp_abc'
check "...and the main ruleset then requires an approval" has_posted '"required_approving_review_count":1'
check "the bot flow does not show the fine-grained page" test "$(grep -c personal-access-tokens/new <<<"${OUT}")" -eq 0

gh_world tartale '' '' 'write'; owner_curl tartalebot 'public_repo, workflow'; new_project
run_init 'y\ntartalebot\ny\nn\nn\nn\n\nghp_abc\n'
check "a bot's token with a powerful scope is still called out" mentions "powerful scopes the agent could use: workflow"

gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project; printf 'true' > "${GHD}/private"
run_init 'y\ntartalebot\ny\nn\nn\nn\n\nghp_abc\n'
check "for a private repo the scope is repo" mentions "settings/tokens/new?scopes=repo&"

# Who may create v* tags: you, as a user on a personal repo (GitHub drops a role bypass there), the admin role for an organization.
gh_world tartale '' '' ''; new_project
run_init 'n\nn\nn\ny\n'
check "on a personal repo the tag ruleset names you as the bypass" has_posted '"bypass_actors":[{"actor_id":101,"actor_type":"User","bypass_mode":"always"}]'
check "...and says you can still tag" mentions "tartale can still create, move or delete v* tags"
gh_world tartale '' '' ''; printf 'Organization' > "${GHD}/ownertype"; new_project
run_init 'n\nn\nn\ny\n'
check "on an organization's repo the tag ruleset uses the admin role" has_posted '"actor_type":"RepositoryRole"'
gh_world tartale '' '' ''; printf '0' > "${GHD}/bypass"; new_project
run_init 'n\nn\nn\ny\n'
check "if GitHub still keeps no bypass, init warns that nobody can tag" mentions "nobody can create a v* tag until you disable"

gh_world tartale '7\tmain\n8\trelease tags\n' '0\tfalse\tfalse\n' ''; printf '0' > "${GHD}/tagbypass"; new_project
run_init 'n\nn\nn\ny\n\n'
check "an existing tag ruleset with no bypass offers to add you" mentions "Let tartale create v* tags"
check "...by updating that ruleset with you as the bypass" grep -qF '"actor_type":"User"' <<<"$(grep 'rulesets/8' "${GHD}/log")"
check "...and says so" mentions "tartale can now create v* tags"
gh_world tartale '7\tmain\n8\trelease tags\n' '0\tfalse\tfalse\n' ''; printf '0' > "${GHD}/tagbypass"; printf '0' > "${GHD}/putbypass"; new_project
run_init 'n\nn\nn\ny\n\n'
check "if the update is dropped too, init warns" mentions "GitHub kept no bypass: nobody can create a v* tag"
gh_world tartale '7\tmain\n8\trelease tags\n' '0\tfalse\tfalse\n' ''; new_project
run_init 'n\nn\nn\ny\n'
check "an existing tag ruleset that already has a bypass is left alone" mentions "ruleset 'release tags' already exists; left alone"

# One bot token for every project: the env file holds a reference to a host variable.
gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
run_init 'y\ntartalebot\ny\nn\nn\ny\n\n\nghp_abc\n'; rc=$?
check "the bot's token can be kept in a shared host variable" mentions "Keep the bot's token in a host variable"
check "...the env file then holds a reference, not the token" contains "${WORK}/proj/.env" 'CS_GITHUB_TOKEN=${CS_BOT_TOKEN}'
check "...and never the token itself" lacks "ghp_abc saved"
check "...nothing of the token is in the env file" test "$(grep -c ghp_abc "${WORK}/proj/.env")" -eq 0
check "...with a comment saying it is shared" contains "${WORK}/proj/.env" "# The bot's GitHub token, shared by all projects"
check "...the token page names the shared token after the bot" mentions "description=claude-sandbox-tartalebot"
check "...and init says where to export it" mentions "export CS_BOT_TOKEN=<the token>"

gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project; INIT_ENV=(CS_BOT_TOKEN=ghp_abc)
run_init 'y\ntartalebot\ny\nn\nn\ny\n\n'; rc=$?; INIT_ENV=()
check "a shared variable that is already set is used without a paste" mentions "using \$CS_BOT_TOKEN from the environment"
check "...no token page, no paste prompt" lacks "Paste the token"
check "...and the reference is stored" contains "${WORK}/proj/.env" 'CS_GITHUB_TOKEN=${CS_BOT_TOKEN}'
check "...without telling you to export it again" lacks "export CS_BOT_TOKEN=<the token>"

gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project; INIT_ENV=(MY_BOT=ghp_abc)
run_init 'y\ntartalebot\ny\nn\nn\ny\nMY_BOT\n'; INIT_ENV=()
check "the variable's name can be chosen" contains "${WORK}/proj/.env" 'CS_GITHUB_TOKEN=${MY_BOT}'
gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
run_init 'y\ntartalebot\ny\nn\nn\ny\nbad name\n'; rc=$?
check "a name that is not a variable name is refused" mentions "not a usable variable name"

gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
printf '# bot\nCS_GITHUB_TOKEN=$CS_BOT_TOKEN\n' > "${WORK}/proj/.env"; INIT_ENV=(CS_BOT_TOKEN=ghp_abc)
run_init '\n\n\nn\nn\n'; INIT_ENV=()
check "a stored reference is resolved: the bot question defaults to yes for the token's owner" mentions "(the stored token belongs to tartalebot)"
check "...and the token question to keeping it, naming the variable" mentions "(the token in \$CS_BOT_TOKEN is tartalebot's)"
gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
printf '# bot\nCS_GITHUB_TOKEN=$CS_BOT_TOKEN\n' > "${WORK}/proj/.env"
run_init 'y\ntartalebot\nn\nn\nn\n'
check "a reference whose variable is not set here says so" mentions "\$CS_BOT_TOKEN is not set in this shell"
check "...in the bot step too" mentions "the host variable CS_BOT_TOKEN holds the token but is not set in this shell"

# The bot question stands on its own: it is asked, and acted on, without creating a token.
gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init 'y\ntartalebot\nn\nn\nn\n'
check "the bot question is asked even when no token is created" mentions "separate bot account"
check "...checking the collaborator" mentions "tartalebot can write to o/Demo-App"
check "...and that the stored token is the bot's" mentions "the stored token belongs to tartalebot"

gh_world tartale '' '' 'write'; owner_curl tartale; new_project
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init 'y\ntartalebot\nn\nn\nn\n'
check "a stored token on the wrong account is reported" mentions "the stored token belongs to tartale, not tartalebot"
check "...saying to create a new one as the bot" mentions "create it while signed in as tartalebot"

gh_world tartale '' '' 'write'; new_project
run_init 'y\ntartalebot\nn\nn\nn\n'
check "with no token stored it says to create one as the bot" mentions "no token is stored yet"

new_project
run_init "" "${ROOT}/host/init.sh --yes"
check "--yes answers the bot question no, without asking for a username" lacks "The bot's GitHub username"
rm -f "${BIN}/gh"; printf '#!/bin/sh\nexit 0\n' > "${BIN}/curl"

# The bot question defaults to yes, with the account's name, when the stored token is another account's.
gh_world tartale '' '' 'write'; owner_curl tartalebot; new_project
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init '\n\nn\nn\nn\n'; rc=$?
check "with a stored bot token the question says so" mentions "(the stored token belongs to tartalebot)"
check "...and Enter accepts it, with the bot's name as the username" mentions "the stored token belongs to tartalebot"
check "...so the bot account step runs" mentions "Bot account tartalebot"

gh_world tartale '' '' 'write'; owner_curl tartale; new_project
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init '\nn\nn\nn\n'
check "a stored token on your own account leaves the default at no" lacks "Bot account"
check "...and does not name an account in the question" lacks "(the stored token belongs to"

gh_world tartale '' '' 'write'; owner_curl tartale; new_project
run_init '\nn\nn\nn\n'
check "with no stored token the default is no" lacks "Bot account"
rm -f "${BIN}/gh"; owner_curl tartalebot
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"; new_project; printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init '\nn\nn\nn\n'; rc=$?
check "without gh the default is no, and nothing breaks" test "${rc}" -eq 0
printf '#!/bin/sh\nexit 0\n' > "${BIN}/curl"

# An existing main ruleset is made stricter only, and only when the stored token is a bot's.
gh_world tartale '7\tmain\n8\trelease tags\n' '0\tfalse\tfalse\n' ''; owner_curl tartalebot; new_project
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init 'n\nn\nn\ny\ny\n'
check "an existing main ruleset is raised to one approval when the token is a bot's" ghlogged '"required_approving_review_count":1'
check "...by an update of that ruleset" test -s "${GHD}/put"
check "...with nothing else created" nothing_posted

gh_world tartale '7\tmain\n8\trelease tags\n' '1\ttrue\ttrue\n' ''; owner_curl tartalebot; new_project
printf 'CS_GITHUB_TOKEN=github_pat_x\n' > "${WORK}/proj/.env"
run_init 'n\nn\nn\ny\n'
check "a ruleset that is already strict enough is left alone" mentions "already as strict as wanted"
check "...and so are existing rulesets, so nothing is written" test ! -e "${GHD}/put" -a ! -e "${GHD}/post-0"

gh_world tartale '7\tmain\n' '2\ttrue\ttrue\n' ''; new_project
run_init 'n\nn\nn\ny\n'
check "a stricter ruleset is never weakened" test ! -e "${GHD}/put"

gh_world tartale '' '' ''; new_project
run_init "" "${ROOT}/host/init.sh --yes"
check "--yes sets up both rulesets without asking" test "$(find "${GHD}" -name 'post-*' | wc -l | tr -d ' ')" -eq 2
rm -f "${BIN}/gh"; printf '#!/bin/sh\nexit 0\n' > "${BIN}/curl"

# --- --yes and --no ----------------------------------------------------------
edited_project
run_init "" "${WORK}/init-changed.sh --yes"; rc=$?
check "--yes finishes without being asked anything" test "${rc}" -eq 0
check "--yes replaces an edited stub whose template changed" contains "${SB}/plugin.sh" '# new header line'
check "...after a backup" test "$(backups plugin.sh)" -eq 1
check "--yes skips the token, which needs a pasted secret" lacks "Paste the token"

# A paste wrapped in bracketed-paste markers is judged by the token inside.
new_project
run_init 'n\ny\nn\nn\n\n\033[200~github_pat_abc\033[201~\n'; rc=$?
check "bracketed-paste markers are stripped from a pasted token" mentions "token cannot read"

# --- classic tokens --------------------------------------------------------------
# A curl that answers as a repo whose token has SCOPES and gets PUSH from the push probe.
classic_curl() {   # PUSH_CODE SCOPES
    cat > "${BIN}/curl" <<EOS
#!/bin/bash
case "\$*" in
    *info/refs*) printf '%s' "$1" ;;
    *api*) printf 'HTTP/2 200\r\nX-OAuth-Scopes: %s\r\n\r\n[]' "$2" ;;
esac
EOS
    chmod +x "${BIN}/curl"
}
ENVF="${WORK}/proj/.env"
classic_curl 200 "repo"
new_project
run_init 'n\ny\nn\nn\n\nghp_abc\nn\n'; rc=$?
check "a classic token is warned about" mentions "reaches every repo your account can"
check "...with the scopes it carries" mentions "scopes: repo"
check "...and refused when you decline" test "${rc}" -ne 0
check "...saying how to do it properly" mentions "create a fine-grained token limited to o/Demo-App"
no_token_stored() { [ ! -f "${ENVF}" ] || ! grep -qF ghp_abc "${ENVF}"; }
check "...storing nothing" no_token_stored

new_project
run_init 'n\ny\nn\nn\n\nghp_abc\ny\n'; rc=$?
check "a classic token is stored when you accept" test "${rc}" -eq 0
check "...in the env file" contains "${ENVF}" 'CS_GITHUB_TOKEN=ghp_abc'
check "...with a comment that says what a classic token is" contains "${ENVF}" '# Classic GitHub token'
check "...and without the fine-grained comment" absent "${ENVF}" 'Fine-grained GitHub token, limited to'
check "the env file stays private" mode_is "${ENVF}" 600

classic_curl 200 "repo, workflow, admin:org"
new_project
run_init 'n\ny\nn\nn\n\nghp_abc\ny\n'
check "powerful scopes are called out" mentions "powerful scopes the agent could use: workflow,admin:org"

classic_curl 403 "repo"
new_project
run_init 'n\ny\nn\nn\n\nghp_abc\ny\n'; rc=$?
check "a classic token that cannot push is rejected" mentions "token cannot push to o/Demo-App"
check "...without asking to continue" lacks "Use a classic token anyway"

classic_curl 200 "repo"
new_project
printf 'CS_GITHUB_TOKEN=ghp_abc\n' > "${ENVF}"
run_init 'n\nn\nn\nn\n'
check "an existing working classic token is recognised" mentions "a classic token is already in"

new_project
run_init "" "${ROOT}/host/init.sh --yes"
check "--yes still takes no token" lacks "Use a classic token anyway"
printf '#!/bin/sh\nexit 0\n' > "${BIN}/curl"
check "--yes does not touch the ruleset without gh" lacks "ruleset created"

edited_project
run_init "" "${WORK}/init-changed.sh --no"; rc=$?
check "--no finishes without being asked anything" test "${rc}" -eq 0
check "--no keeps an edited stub" contains "${SB}/plugin.sh" 'mypkg'
check "...and makes no backup" test "$(backups plugin.sh)" -eq 0

new_project
OUT=$(bash "${ROOT}/host/init.sh" --yes --no 2>&1); rc=$?
check "--yes with --no is an error" test "${rc}" -eq 2

# --- start.sh: restart policy ---------------------------------------------------
new_project
run_init "${NO3}"
SS="${WORK}/start"
mkdir -p "${SS}/host" "${SS}/bin"
cp "${ROOT}/host/start.sh" "${ROOT}/host/lib.sh" "${SS}/host/"
printf '#!/bin/sh\necho "$CS_DOCKER_FLAGS" > %s/flags\n' "${SS}" > "${SS}/host/claude-sandbox.sh"
printf '#!/bin/sh\nexit 1\n' > "${SS}/bin/docker"
chmod +x "${SS}/host/claude-sandbox.sh" "${SS}/bin/docker"
start() { OUT=$(env -i PATH="${SS}/bin:${BIN}" CS_PROJECT_DIR="${SS}" CS_PROJECT_NAME=Demo-App "$@" bash "${SS}/host/start.sh" 2>&1); }
start
check "start.sh runs the container detached with --restart=unless-stopped" contains "${SS}/flags" '-d -t --restart=unless-stopped'
start CS_DOCKER_FLAGS="--restart=no"
check "a --restart in CS_DOCKER_FLAGS comes after it, so it wins" contains "${SS}/flags" '--restart=unless-stopped --restart=no'

# --- launcher pin ---------------------------------------------------------------
SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
REAL_GIT=$(command -v git)
rm -f "${BIN}/git"
cat > "${BIN}/git" <<WRAP
#!/bin/sh
if [ "\$1" = ls-remote ]; then
    [ -n "\$LSR_FAIL" ] && exit 1
    printf '%s\trefs/heads/main\n' "\$(cat ${WORK}/lsr-main)"
    printf '%s\trefs/heads/dev\n' ${SHA2}
    exit 0
fi
exec ${REAL_GIT} "\$@"
WRAP
chmod +x "${BIN}/git"
echo "${SHA1}" > "${WORK}/lsr-main"

new_project
run_init "${NO3}"
check "init pins the launcher to main's commit" contains "${SB}/ref" "${SHA1}"
check "...and reports it" mentions "pinned to 1111111"
check "the stubs read the pin" contains "${SB}/build.sh" '${THIS_SCRIPT_DIR}/ref'
echo "${SHA2}" > "${WORK}/lsr-main"
run_init "${NO3}"
check "running init again moves the pin" contains "${SB}/ref" "${SHA2}"
check "...and reports the old commit" mentions "was 1111111"
run_init "${NO3}"
check "an unchanged pin is reported as staying" mentions "stays at 2222222"
OUT=$(cd "${WORK}/proj" && printf "${NO3}" | env -i PATH="${BIN}" HOME="${WORK}/home" NO_COLOR=1 CS_REF=dev \
    script -qec "bash ${ROOT}/host/init.sh" /dev/null 2>&1 | tr -d '\r')
check "CS_REF chooses the ref to pin" contains "${SB}/ref" "${SHA2}"
OUT=$(cd "${WORK}/proj" && printf "${NO3}" | env -i PATH="${BIN}" HOME="${WORK}/home" NO_COLOR=1 CS_REF=${SHA1} \
    script -qec "bash ${ROOT}/host/init.sh" /dev/null 2>&1 | tr -d '\r')
check "a commit SHA is pinned without a lookup" contains "${SB}/ref" "${SHA1}"
OUT=$(cd "${WORK}/proj" && printf "${NO3}" | env -i PATH="${BIN}" HOME="${WORK}/home" NO_COLOR=1 CS_REF=latest \
    script -qec "bash ${ROOT}/host/init.sh" /dev/null 2>&1 | tr -d '\r')
check "CS_REF=latest removes an existing pin" test ! -e "${SB}/ref"
check "...and says the launcher follows main" mentions "the launcher follows main"
check "...without warning that the ref could not be resolved" lacks "could not resolve"
new_project
OUT=$(cd "${WORK}/proj" && printf "${NO3}" | env -i PATH="${BIN}" HOME="${WORK}/home" NO_COLOR=1 LSR_FAIL=true \
    script -qec "bash ${ROOT}/host/init.sh" /dev/null 2>&1 | tr -d '\r')
check "an unresolvable ref writes no pin" test ! -e "${SB}/ref"
check "...and warns that main is used" mentions "fetch main"
new_project; run_init "${NO3}" >/dev/null
RP="${WORK}/refpin"
mkdir -p "${RP}/.claude/sandbox" "${RP}/bin"
cp "${SB}/start.sh" "${RP}/.claude/sandbox/start.sh"
printf '#!/bin/sh\nfor a; do u=$a; done\necho "$u" > %s/url\n' "${RP}" > "${RP}/bin/curl"
printf '#!/bin/sh\nexit 1\n' > "${RP}/bin/docker"
chmod +x "${RP}/bin/curl" "${RP}/bin/docker"
fetched() { env -i PATH="${RP}/bin:${BIN}" "$@" bash "${RP}/.claude/sandbox/start.sh" >/dev/null 2>&1; cat "${RP}/url"; }
check "CS_REF=latest makes the stub follow main" contains <(fetched CS_REF=latest) "/claude-sandbox/main/"
check "with no pin the stub fetches main" contains <(fetched) "/claude-sandbox/main/"
echo "${SHA1}" > "${RP}/.claude/sandbox/ref"
check "with a pin the stub fetches that commit" contains <(fetched) "/claude-sandbox/${SHA1}/"
check "CS_REF beats the pin" contains <(fetched CS_REF=dev) "/claude-sandbox/dev/"

# --- prerequisites ----------------------------------------------------------
new_project
rm -f "${BIN}/envsubst"
run_init "${NO3}"; rc=$?
check "a missing envsubst stops init" test "${rc}" -ne 0
check "...before asking anything" lacks "Create and store"
check "...and says how to install it" mentions "gettext-base"
check "...creating no stubs" test ! -e "${SB}/build.sh"
printf '#!/bin/sh\ncat\n' > "${BIN}/envsubst"; chmod +x "${BIN}/envsubst"

# --- usage ------------------------------------------------------------------
OUT=$(bash "${ROOT}/host/init.sh" --help 2>&1); rc=$?
check "--help exits 0" test "${rc}" -eq 0
OUT=$(bash "${ROOT}/host/init.sh" --bogus 2>&1); rc=$?
check "an unknown option is an error" test "${rc}" -eq 2

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
