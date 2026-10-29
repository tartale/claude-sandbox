#!/usr/bin/env bash
set -euo pipefail

RUBY_VERSION=$(echo "${CS_LANGUAGE_VERSIONS:-}" | tr ' ' '\n' | grep '^ruby-' | head -1 | sed 's/ruby-//') || true

apt-get update
apt-get install -y \
  ruby \
  ruby-dev \
  build-essential \
  libssl-dev \
  libreadline-dev \
  zlib1g-dev
rm -rf /var/lib/apt/lists/*

if [ -n "$RUBY_VERSION" ]; then
    git clone https://github.com/rbenv/ruby-build.git /usr/local/share/ruby-build
    /usr/local/share/ruby-build/bin/ruby-build "$RUBY_VERSION" "/usr/local/ruby-$RUBY_VERSION"
    ln -sf "/usr/local/ruby-$RUBY_VERSION/bin/ruby" /usr/local/bin/ruby
    ln -sf "/usr/local/ruby-$RUBY_VERSION/bin/gem" /usr/local/bin/gem
fi

gem install bundler
