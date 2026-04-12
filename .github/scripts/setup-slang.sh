#!/usr/bin/env bash
# Download and configure the latest Slang release for CI.
#
# Environment:
#   SLANG_INSTALL_DIR — extraction target (default: ~/slang)
#   SLANG_VERSION     — override version (skips API query if set)
#   GH_TOKEN          — GitHub token for API requests (avoids rate limits)
#   GITHUB_PATH       — GitHub Actions PATH file
#   GITHUB_OUTPUT     — GitHub Actions step output file
#
# Skips download when $SLANG_INSTALL_DIR/bin/slangc already exists (cache hit).

set -euo pipefail

INSTALL_DIR="${SLANG_INSTALL_DIR:-$HOME/slang}"

# --- Determine version ---
if [[ -z "${SLANG_VERSION:-}" ]]; then
    echo "Querying latest Slang release..."
    if command -v gh &>/dev/null && [[ -n "${GH_TOKEN:-}" ]]; then
        SLANG_VERSION=$(gh api repos/shader-slang/slang/releases/latest --jq '.tag_name | ltrimstr("v")')
    else
        SLANG_VERSION=$(curl -fsSL https://api.github.com/repos/shader-slang/slang/releases/latest | jq -r '.tag_name | ltrimstr("v")')
    fi
fi
echo "Slang version: $SLANG_VERSION"

# Export for cache key
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "version=$SLANG_VERSION" >> "$GITHUB_OUTPUT"
fi

# --- Check cache ---
if [[ -x "$INSTALL_DIR/bin/slangc" ]]; then
    echo "Slang already installed (cache hit)"
    echo "$INSTALL_DIR/bin" >> "$GITHUB_PATH"
    "$INSTALL_DIR/bin/slangc" -v || true
    exit 0
fi

# --- Download and extract ---
URL="https://github.com/shader-slang/slang/releases/download/v${SLANG_VERSION}/slang-${SLANG_VERSION}-linux-x86_64.tar.gz"
echo "Downloading: $URL"

mkdir -p "$INSTALL_DIR"
curl -fsSL "$URL" | tar -xz -C "$INSTALL_DIR"

# Verify
if [[ ! -x "$INSTALL_DIR/bin/slangc" ]]; then
    echo "::error::slangc not found at $INSTALL_DIR/bin/slangc after extraction"
    echo "Archive contents:"
    ls -la "$INSTALL_DIR/"
    exit 1
fi

echo "$INSTALL_DIR/bin" >> "$GITHUB_PATH"
"$INSTALL_DIR/bin/slangc" -v
