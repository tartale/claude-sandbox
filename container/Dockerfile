# Pinned by digest so a changed or compromised tag cannot alter the image; dependabot (see
# .github/dependabot.yml) proposes the update when node:22-slim moves.
FROM node:25-slim@sha256:81db02c4b671288a03915da9534dbd54f96d0e7c24d80ccc54f5b36b2e684370

RUN apt-get update \
 && apt-get install -y ca-certificates curl \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /usr/share/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y \
      gh \
      git \
      git-lfs \
      jq \
      less \
      lsof \
      make \
      openssh-client \
      procps \
      python3 \
      ripgrep \
      shellcheck \
      tree \
      unzip \
      vim \
      wget \
      zip \
 && rm -rf /var/lib/apt/lists/* \
 && git lfs install --system

ARG CLAUDE_VERSION=latest
ARG NPM_REGISTRY=https://registry.npmjs.org/
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm_config_registry="$NPM_REGISTRY" npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}

# Rename the default 'node' user/group to 'claude'
RUN usermod -l claude -d /home/claude -m node \
 && groupmod -n claude node

WORKDIR /workspace
RUN chown claude:claude /workspace

COPY plugins/install.sh /usr/local/bin/install-plugins.sh
COPY container/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY container/github-config.sh /usr/local/bin/github-config.sh
COPY container/setup-scopes.sh /usr/local/bin/setup-scopes.sh
COPY container/user-sync.sh /usr/local/bin/claude-user-sync
COPY container/user-pull.sh /usr/local/bin/claude-user-pull
COPY container/claude-settings.json /usr/local/share/claude-sandbox/settings.json
RUN chmod +x /usr/local/bin/install-plugins.sh /usr/local/bin/entrypoint.sh \
             /usr/local/bin/setup-scopes.sh /usr/local/bin/claude-user-sync /usr/local/bin/claude-user-pull

ARG CS_LANGUAGE_VERSIONS=""
ARG PLUGINS=""
RUN --mount=type=bind,target=/build \
    --mount=type=secret,id=npmrc,target=/root/.npmrc \
    if [ -n "$PLUGINS" ]; then \
        npm_config_registry="$NPM_REGISTRY" install-plugins.sh "/build/$PLUGINS"; \
    fi

ENV CUID=1000
ENV CGID=1000
ENV CMASK=0002

ENTRYPOINT ["entrypoint.sh"]
