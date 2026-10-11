---
name: launcher-compat-breaks-are-silent
description: claude-sandbox launcher changes tend to break users silently (.env semantics, launcher vars, hardening flags); warn loudly instead
metadata:
  type: project
---

`claude-sandbox.sh` used to `source` the project `.env` on the host, so `.env` values were shell-evaluated and could set launcher variables (`DOCKER_FLAGS`, `CS_USER_CONFIG`). Reading `.env` as data (#13, reverted in #14) silently dropped both behaviors — no error at launch, just a missing docker socket or a literal `${VAR}` token.

**Why:** the silent failure was the real compatibility cost, not the semantics change itself.

**How to apply:** when changing how the launcher parses config or sets `docker run` flags, detect the old usage and print a warning at launch; test old vs. new launcher against the same input with a stub `docker` (under `script -qec` for a pty). Runtime `PLUGINS` (apt-get as root) and the docker-socket group step in `entrypoint.sh` need capabilities beyond the obvious; the react/playwright plugins were not tested under `--cap-drop=ALL`. Related: [[no-merge-without-approval]].
