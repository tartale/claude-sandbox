---
name: no-merge-without-approval
description: claude-sandbox only — never merge a PR (even green CI, even a revert) without the user's explicit approval; users run the launcher straight from main
metadata:
  type: feedback
---

In this repo, open the PR, get CI green, then **stop and ask** — merge only after the user says so. This overrides the user-scope "merge on green without asking" rule for this project only.

**Why:** users run the launcher straight from `main` (`curl … refs/heads/main/claude-sandbox.sh | bash`), so a merge reaches everyone on their next launch, and `docker-publish.yml` rebuilds `:latest` on every push to `main`. On 2026-09-29 a merged change (#13: `.env` parsed as data + capability hardening) made a relaunched container hang; it had to be rolled back in #14 (#15 re-proposes it as a draft).

**How to apply:** applies to every merge here, including reverts and one-line fixes. Say what is waiting ("#N green, awaiting your OK") and wait. Ship risky launcher/Dockerfile changes as draft PRs and test them against the real image before asking. Also see [[launcher-compat-breaks-are-silent]].
