# Rules, memories and Claude state

Claude accumulates two kinds of knowledge that belong in different places:

- **Project scope**: how this codebase is built, tested and deployed, its gotchas and ongoing work. It travels with the repo, so a `git pull` brings it to a teammate or another machine.
- **User scope**: who you are and how you like to work. It follows you between projects and machines, and has no place in one project's history.

Every project is mounted at `/workspace`, so Claude Code would give them all one project key and pile every project's memories, transcripts and history into a single `~/.claude/projects/-workspace/` bucket. The sandbox splits them.

## Claude state

The launcher does not mount your host `~/.claude` or `~/.claude.json`. A sandbox that could would see every other project's transcripts and plans, and could plant settings, hooks or skills that run the next time you use Claude Code on the host. Instead each project has `~/.claude-sandbox/<project name>/` with its own `.claude/` and `.claude.json`. The directory is named after the project's folder, not its path, so moving a project keeps its state; two projects with the same folder name share one.

Only your credentials are carried between them, at each start: the launcher copies `~/.claude/.credentials.json` into the project's directory, and copies the project's file back to the host when the sandbox renewed it (the newer copy wins). A `/login` in one sandbox reaches the others when they next start. Your host settings, skills, commands and plugins are not visible in the sandbox. On macOS, where Claude Code keeps credentials in the Keychain, log in once inside the sandbox; they are then kept in that file.

## Project scope

The project's memory directory is bind-mounted from the project itself:

```
<project>/CLAUDE.md                    project rules            (commit)
<project>/.claude/memory/              project memories         (commit)
<project>/.claude/settings.json        shared project settings  (commit)
<project>/.claude/settings.local.json  machine-local overrides  (gitignore)
```

Memories recorded in a session land in `.claude/memory/` and are committed with the code they describe. Add `.claude/settings.local.json` to the project's `.gitignore`; nothing else under `.claude/` should be ignored.

## User scope

User rules and memories live in a small private git repo (for example `you/claude-user`) that every sandbox clones read-only at start. `init.sh` adds the repo and a token to `.env`, commented out, with the repo pre-filled as `<project owner>/claude-user`:

```bash
# .env
CS_USER_CONFIG_REPO=you/claude-user
CS_USER_CONFIG_TOKEN=github_pat_...   # fine-grained, only that repo, Contents: Read-only
```

Both are optional and must be set together (a repo without a token is skipped with a warning); without them the session has no user scope and says so. They can also be exported in your shell. The sandbox can read `.env`, so the token is readable inside it, but it can only read that repo. Do not give the project's sandbox token access to this repo, or the protection is moot.

The repo is cloned to `/home/claude/.claude-user` and scaffolded on first use:

```
CLAUDE.md          your rules, loaded into every session on every project
memory/MEMORY.md   index of your user-scope memories
memory/*.md        the memories themselves
```

At container start the sandbox generates `~/.claude/CLAUDE.md` from it: the scope routing rules, your `CLAUDE.md` and your memory index, inlined so Claude always has them. It is regenerated on every start; edit the repo's `CLAUDE.md` instead.

The session can read but never push. The clone vanishes with the container, so `claude-user-sync` commits locally and writes `.tmp/claude-user.patch` in the project. Review and apply it from your own checkout with the generated stub:

```bash
.claude/sandbox/sync.sh          # apply (the default)
.claude/sandbox/sync.sh show     # page through the patch
.claude/sandbox/sync.sh status   # say whether one is waiting
```

`apply` shows what the patch changes (`d` for the colored diff), asks, then runs `git am` in the checkout named by `CS_USER_CONFIG_CHECKOUT` (default `~/.claude-user`) and pushes. The script is read-only in the sandbox like the other launch scripts.

### Keeping running sessions current

Changes you push to the user repo reach a running session by themselves. The container gives Claude Code a `UserPromptSubmit` hook (via `--settings`, so your own settings are untouched) that runs `claude-user-pull --hook` before each prompt. At most every five minutes it fetches the repo, and if something new landed it updates the clone and adds "user preferences changed" plus the diff to the agent's context. If the clone has unapplied local changes, it reports the change without pulling and tells the agent to run `claude-user-sync` first. To check on demand, run `claude-user-pull` inside the sandbox.

## Which scope does something belong in?

Ask whether it would still be true on a different project. "Run the full test suite before pushing" is user scope; "run `./actual test` before pushing" is project scope. Claude is given this rule in the generated `CLAUDE.md`.
