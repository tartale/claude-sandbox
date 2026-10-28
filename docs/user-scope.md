# Rules, memories and Claude state

Claude accumulates two very different kinds of knowledge, and they want to live in different places:

- **Project scope** — how *this* codebase is built, tested and deployed; its gotchas and ongoing work. This should travel with the repo, so a teammate (or you on another machine) gets it from a `git pull`.
- **User scope** — who you are and how you like to work. This should follow *you* between projects and between machines, and has no business in any one project's history.

Left alone, the sandbox blurs both. Every project is mounted at `/workspace`, so Claude Code derives the same project key for all of them and piles every project's memories, transcripts and history into a single `~/.claude/projects/-workspace/` bucket on the host. The sandbox splits them instead.

## Claude state

The launcher does not mount your host `~/.claude` or `~/.claude.json`. A sandbox that could would see every other project's transcripts and plans, and could plant settings, hooks or skills there that run the next time you use Claude Code on the host. Instead each project has `~/.claude-sandbox/<project name>/` with its own `.claude/` and `.claude.json`.

Your credentials are the only thing carried between them, and the launcher does it at each start: it copies `~/.claude/.credentials.json` into the project's directory, and copies the project's file back to the host when the sandbox renewed it (the newer copy wins). The directory is named after the project's folder, not its full path, so moving a project keeps its state; two projects with the same folder name share one. A `/login` inside any sandbox therefore reaches the others when they next start. Settings, skills, commands and plugins in your host `~/.claude` are not visible in the sandbox. On macOS, where Claude Code keeps credentials in the Keychain, log in once inside the sandbox; the credentials are then kept in the file above.

## Project scope

Each project gets its own state directory on the host, keyed by the project's directory name (see [Claude state](#claude-state)), and its memory directory is bind-mounted from the project itself:

```
<project>/CLAUDE.md                    project rules            (commit)
<project>/.claude/memory/              project memories         (commit)
<project>/.claude/settings.json        shared project settings  (commit)
<project>/.claude/settings.local.json  machine-local overrides  (gitignore)
```

`.claude/memory/` is the directory Claude writes memories to, so memories recorded during a session land in the project and get committed alongside the code they describe. Add this to the project's `.gitignore`:

```gitignore
.claude/settings.local.json
```

Nothing else under `.claude/` should be ignored — that's the point.

## User scope

User-scope rules and memories live in a small private git repo (for example `you/claude-user`) that every sandbox clones read-only at start. Give the sandbox the repo and a token that can only read it; `init.sh` adds both to `.env`, commented out, with the repo pre-filled as `<project owner>/claude-user`:

```bash
# .env
CS_USER_CONFIG_REPO=you/claude-user
CS_USER_CONFIG_TOKEN=github_pat_...   # fine-grained, only that repo, Contents: Read-only
```

Both are optional: without them the session has no user scope and says so. Set the two together; a repo without a token is skipped with a warning. They can equally be exported in your shell instead of `.env`. The sandbox can read `.env`, so the token is readable inside it; it can only read that repo.

The repo is cloned to `/home/claude/.claude-user` and scaffolded on first use:

```
CLAUDE.md          your rules, loaded into every session on every project
memory/MEMORY.md   index of your user-scope memories
memory/*.md        the memories themselves
```

At container start the sandbox generates `~/.claude/CLAUDE.md` from it: the scope routing rules, your `CLAUDE.md`, and your memory index, inlined so Claude always has them. That file is regenerated on every start; edit the repo's `CLAUDE.md` instead.

The token stays in the environment, but it can only read, so the session can fetch later changes and can never push them. The clone vanishes with the container. `claude-user-sync` commits locally and writes `.tmp/claude-user.patch` in the project; review it and apply it from your own checkout with the stub `init.sh` generated:

```bash
.claude/sandbox/sync.sh
```

Page through the patch:

```bash
.claude/sandbox/sync.sh show
```

Say whether one is waiting:

```bash
.claude/sandbox/sync.sh status
```

`apply` (the default) shows what the patch changes (`d` shows the colored diff), asks before applying, then runs `git am` in the checkout named by `CS_USER_CONFIG_CHECKOUT` (default `~/.claude-user`) and pushes. The script is mounted read-only in the sandbox like the other launch scripts, so a session cannot edit it.

### Keeping running sessions current

Changes you push to the user config repo reach a running session by themselves. The container passes Claude Code a `UserPromptSubmit` hook (`--settings`, so your own settings are untouched) that runs `claude-user-pull --hook` before each prompt. At most every five minutes it fetches the repo; if something new landed, it brings the clone up to date and puts "user preferences changed" plus the diff into the agent's context. You do not need to tell each agent to re-read. If the clone has local changes that are not applied yet, it reports the change without pulling and tells the agent to run `claude-user-sync` first. To check on demand, run this inside the sandbox:

```bash
claude-user-pull
```

Don't grant the project's sandbox token access to the user config repo, or the protection is moot.

## Which scope does something belong in?

Ask whether it would still be true on a different project. "Run the full test suite before pushing" is user scope; "run `./actual test` before pushing" is project scope. Claude is given this rule in the generated `CLAUDE.md`, but it's worth knowing when you're filing things by hand.
