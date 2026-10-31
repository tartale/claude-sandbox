# Security

What the sandbox protects, and what it leaves to you.

## What the agent can and cannot change

Mounted read-only inside the container, because they run on the host later (at launch, on `cd` with direnv, or on commit) and an agent must not plant code in them: the env file, `.envrc`, `.envrc-cs`, `.git/config`, `.git/hooks`, `.claude/sandbox/ref` and `.claude/sandbox/{build,restart,run,start,sync}.sh`. Edit them from the host.

- `.claude/sandbox/plugin.sh` stays writable so the agent can maintain the project's dependencies. It runs only inside the image build; read its `git diff` before `build.sh`.
- Because `.git/config` is read-only, a session cannot add an alias, `core.fsmonitor` or `core.sshCommand` for your host git to run. Git inside the container does not record upstream tracking, so `git push -u` pushes but prints an error, and `git remote add`, `git config` and `git branch --set-upstream-to` fail. Do those on the host; a running container keeps the old `.git/config` until it restarts.
- Other files that run on the host later (test and package scripts) stay writable: read `git diff` before running host-side tooling on a checkout an agent has touched.
- The container drops all capabilities except `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID` and `SETGID`, and sets `no-new-privileges`.

## GitHub token

`CS_GITHUB_TOKEN` (in `.env`) lets `git` and `gh` authenticate inside the container. Whatever the token can do, the agent can do.

**With a bot account (recommended).** The sandbox is a separate GitHub account with the Write role, and its PRs need your approval ([Merge gate](#merge-gate)). Fine-grained tokens cannot reach another user's repo, so the bot's token is classic (`ghp_`). It cannot be limited to one repository, but it reaches only what the bot can access: invite the bot only to repos the agent may touch, and give the token the fewest scopes that work (`public_repo` for a public repo, `repo` for a private one; never `workflow` or `admin:*`). `init.sh` checks that it can read and push to this repo, lists its scopes and flags powerful ones. One token can serve every project through a host variable (default `CS_BOT_TOKEN`); the agent can read it, so rotate it at once if it leaks.

**Without a bot account.** The token acts as you. `init.sh` walks you through a [fine-grained token](https://github.com/settings/personal-access-tokens) limited to this repository, with Contents, Pull requests and Issues write access and no Administration or Workflows permission. It checks push access, no Administration and no other private repos; it cannot probe the Workflows permission, so confirm that is off on the token page. A classic token is accepted only after a warning and a confirmation (default no). Nothing then stops the agent merging its own PRs.

`--yes` never takes a token.

## Merge gate

The `main` ruleset requires one approval from someone other than the author, counted only after the last push, with required checks (`shellcheck` and `test` here), no force-push or deletion, and no bypass. The bot cannot approve its own PR, so you approve and merge each one.

Without a bot, nothing stops a session merging its own PR: the token acts as you, GitHub will not count your approval of it, and "do not merge without approval" is only a rule you gave the agent.

`init.sh` sets this up. Answer yes to "Use a separate bot account for the sandbox's token" and give the bot's username (a token already in `.env` that belongs to another account makes it the default). It checks the bot has the Write role (offering to invite it), checks the token really belongs to the bot, and sets the ruleset. A re-run raises an existing ruleset after asking and never lowers one. By hand:

1. Invite the bot with the Write role (Settings, Collaborators) and accept as the bot.
2. As the bot, create a classic token (above) and give it to the sandbox with `cs init`. Each project's `.env` then holds `CS_GITHUB_TOKEN=${CS_BOT_TOKEN}`, which the launcher expands from the host environment.
3. As the repo admin, from the project, require the approval:

   ```bash
   R=$(gh repo view --json nameWithOwner -q .nameWithOwner) && RID=$(gh api "repos/$R/rulesets" --jq '.[] | select(.name=="main") | .id') && gh api "repos/$R/rulesets/$RID" | jq '{name,target,enforcement,bypass_actors,conditions,rules} | (.rules[] | select(.type=="pull_request") | .parameters) += {"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true,"require_last_push_approval":true}' | gh api -X PUT "repos/$R/rulesets/$RID" --input -
   ```

4. Approve and merge each PR in GitHub or with [`cs pr`](#owner-commands). A push after your approval needs a new one.

Check from the sandbox: open a PR and run `gh pr merge <number> --merge`. It must be refused until you approve. Keep `bypass_actors` empty, or the admin role can merge without approval. Treat the bot account as sensitive as the agent: never give it Administration, and use two-factor authentication.

## CI

- CI runs what the PR contains, including `plugin.sh`, the Dockerfile and the workflows. Keep registry and deploy secrets out of workflows that run on PRs, and build and push images only from `main` or tags (`release.yml` runs on tags only, behind the `release` environment's approval).
- Give every workflow an explicit `permissions:` block, read-only for PR workflows, so the repository's default `GITHUB_TOKEN` setting does not matter. As admin you can also set that default to read (Settings, Actions, General) and check it with `gh api repos/OWNER/NAME/actions/permissions/workflow --jq .default_workflow_permissions`, which needs admin and cannot run in the sandbox.
- Pin every action by commit SHA, with the tag in a comment. All of this repo's are, a test fails if one is not, and Dependabot keeps the pins current.
- Read the diff of `plugin.sh`, the Dockerfile, `.github/` and `.claude/sandbox/` before merging.

## Tags

`release.yml` runs on any `v*` tag but waits for your approval (the `release` environment), so a tag the agent pushes cannot publish. `init.sh` also adds a ruleset that stops the agent creating, moving or deleting those tags, with you as the one bypass so you can still tag. On an organization's repo the bypass is the admin role; on a user's repo it is that user, because GitHub drops a role bypass there. The bot is another user, so it stays bound. Re-run `init.sh` to add a missing bypass; it asks first. By hand (personal-repo form):

```bash
R=$(gh repo view --json nameWithOwner -q .nameWithOwner) && ME=$(gh api user --jq .id) && printf '{"name":"release tags","target":"tag","enforcement":"active","bypass_actors":[{"actor_id":%s,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}]}' "$ME" | gh api -X POST "repos/$R/rulesets" --input -
```

Check from the sandbox: `git push origin HEAD:refs/tags/v0.0.0-probe` must be refused. If it succeeds, the token acts as the bypass user: delete the probe (`git push origin --delete v0.0.0-probe`) and fix the token's account.

## Base image

`container/Dockerfile` pins `node:22-slim` by digest, so a moved or compromised tag cannot change your image. Dependabot proposes new digests weekly; review them like any PR. To update by hand, `docker buildx imagetools inspect node:22-slim` prints the digest.

## Owner commands

`cs pr` and `cs release` do the owner's steps of the gate. They need `gh` signed in as the repo's admin (not the bot) and use the current directory's repo (`--repo OWNER/NAME` names another).

```bash
./cs pr list
./cs pr approve 123
./cs pr merge 123
./cs release tag v1.2.3
./cs release approve v1.2.3
```

Name several actions to run them in order on one question, and several PR numbers to run each in turn, with its own question; the first that cannot go stops the rest:

```bash
./cs pr approve merge 123 124
./cs release tag approve v1.2.3
```

`approve` and `merge` show the title, author, review state, checks and changed files first, and refuse while checks are running or failing, or for your own PRs. `release tag` shows the commit it will tag and needs the `release tags` ruleset to let you bypass. `release approve` approves the waiting release run. `--yes` skips the questions.

They act with your admin login and also run from the one-liner, so the version of `claude-sandbox` matters. From the one-liner they use the project's pinned ref (`.claude/sandbox/ref`, written by `init.sh`; only a PR you approve can change it), else `CS_REF=<commit>`, else `main`. They print the version and whether it is pinned. Only the small bootstrap script comes from `main`. Other `cs` commands ignore the pin, so `cs init` can move it.

## Network egress

By default the container can reach any host, including your LAN, so anything the session can read (the project token, the user-config token, the Claude login) can be sent out. Limiting that has to happen outside the container, which has no `NET_ADMIN`. See [Network isolation](network-isolation.md) for the options and `cs network`, and [UniFi](unifi.md) for a worked, verified setup.

Even with allow-listed hosts, a hostile process can leak small amounts of data in DNS lookups. That gap is described, with a fix, in [Network isolation](network-isolation.md#the-dns-channel).
