#!/usr/bin/env bash
# Download and configure the latest Zig master (nightly) build for CI.
# Version is resolved at runtime from https://ziglang.org/download/index.json.
#
# Environment:
#   ZIG_INSTALL_DIR  — extraction target (default: ~/zig)
#   GITHUB_PATH      — GitHub Actions PATH file
#   GITHUB_OUTPUT    — GitHub Actions step output file
#
# Skips download when $ZIG_INSTALL_DIR/zig already exists at the correct version.

set -euo pipefail

INSTALL_DIR="${ZIG_INSTALL_DIR:-$HOME/zig}"

# --- Resolve download URL from index ---
INDEX_JSON=$(curl -fsSL https://ziglang.org/download/index.json)
ZIG_VERSION=$(echo "$INDEX_JSON" | jq -r '.master.version')
URL=$(echo "$INDEX_JSON" | jq -r '.master["x86_64-linux"].tarball')
echo "Zig master: $ZIG_VERSION"

# Export for cache key
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "version=$ZIG_VERSION" >> "$GITHUB_OUTPUT"
fi

# --- Check cache ---
if [[ -x "$INSTALL_DIR/zig" ]]; then
    installed=$("$INSTALL_DIR/zig" version 2>/dev/null || true)
    if [[ "$installed" == "$ZIG_VERSION" ]]; then
        echo "Zig $ZIG_VERSION already installed (cache hit)"
        echo "$INSTALL_DIR" >> "$GITHUB_PATH"
        exit 0
    fi
    echo "Cached version ($installed) does not match, re-downloading"
    rm -rf "$INSTALL_DIR"
fi
echo "Downloading: $URL"

mkdir -p "$INSTALL_DIR"
curl -fsSL "$URL" | tar -xJ --strip-components=1 -C "$INSTALL_DIR"

echo "$INSTALL_DIR" >> "$GITHUB_PATH"
"$INSTALL_DIR/zig" version
