#!/usr/bin/env bash
set -euo pipefail

CPP_VERSION=$(echo "${CS_LANGUAGE_VERSIONS:-}" | tr ' ' '\n' | grep '^cpp-' | head -1 | sed 's/cpp-//') || true
CLANG_MAJOR="${CPP_VERSION%%.*}"

apt-get update
apt-get install -y \
  build-essential \
  cmake \
  gdb \
  ninja-build \
  pkg-config \
  valgrind \
  wget
rm -rf /var/lib/apt/lists/*

if [ -n "$CLANG_MAJOR" ]; then
    wget -qO- https://apt.llvm.org/llvm.sh | bash -s -- "$CLANG_MAJOR"
    apt-get install -y "clang-format-${CLANG_MAJOR}" "clang-tidy-${CLANG_MAJOR}"
    ln -sf "/usr/bin/clang-${CLANG_MAJOR}"        /usr/local/bin/clang
    ln -sf "/usr/bin/clang++-${CLANG_MAJOR}"       /usr/local/bin/clang++
    ln -sf "/usr/bin/clang-format-${CLANG_MAJOR}"  /usr/local/bin/clang-format
    ln -sf "/usr/bin/clang-tidy-${CLANG_MAJOR}"    /usr/local/bin/clang-tidy
    rm -rf /var/lib/apt/lists/*
else
    apt-get update
    apt-get install -y clang clang-format clang-tidy
    rm -rf /var/lib/apt/lists/*
fi
