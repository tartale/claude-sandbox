#!/usr/bin/env bash
set -euo pipefail

# Installs Playwright and the system libraries its browsers need, so a project's end-to-end tests
# can drive a real browser inside the sandbox. Playwright's browsers are headless natively, so
# unlike Cypress this needs no Xvfb wrapper -- `npx playwright test` just runs.
#
# Both Chromium and Firefox are installed: Chromium is the default target, but it has been seen to
# get OOM-killed in this container on heavier pages, and Firefox is the fallback that survives it.

PW_VERSION=$(echo "${LANGUAGE_VERSIONS:-}" | tr ' ' '\n' | grep '^playwright-' | head -1 | sed 's/playwright-//') || true

# Browsers go to a shared, world-readable path rather than a user home. The image is built as root
# but runs as `claude` with a uid remapped at start (see CUID/CGID in the Dockerfile), so anything
# cached under /root -- Playwright's default -- would be unreadable at runtime.
export PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

npm install -g \
  "playwright${PW_VERSION:+@$PW_VERSION}" \
  "@playwright/test${PW_VERSION:+@$PW_VERSION}"

# --with-deps is the part that apt-installs libnss3/libgbm/libasound and the rest of the browser
# runtime; without it the browsers download fine and then fail to launch.
apt-get update
playwright install --with-deps chromium firefox
rm -rf /var/lib/apt/lists/*

chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"

# The browsers live outside any HOME, so every shell has to be told where to find them: profile.d
# covers login shells, bash.bashrc the interactive non-login ones tooling tends to spawn.
printf 'export PLAYWRIGHT_BROWSERS_PATH=%s\n' "$PLAYWRIGHT_BROWSERS_PATH" > /etc/profile.d/playwright.sh
chmod 0644 /etc/profile.d/playwright.sh
printf 'export PLAYWRIGHT_BROWSERS_PATH=%s\n' "$PLAYWRIGHT_BROWSERS_PATH" >> /etc/bash.bashrc
