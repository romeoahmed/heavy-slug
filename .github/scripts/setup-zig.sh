#!/usr/bin/env bash
# Resolve, download, and configure Zig for CI.
#
# Environment:
#   ZIG_VERSION       — from-zon | stable | latest | master | explicit version
#                       (default: from-zon)
#   ZIG_TARGET        — Zig download target (default: x86_64-linux)
#   ZIG_DOWNLOAD_URL  — optional pre-resolved tarball URL
#   ZIG_INSTALL_DIR   — extraction target (default: ~/zig)
#   GITHUB_PATH       — GitHub Actions PATH file
#   GITHUB_OUTPUT     — GitHub Actions step output file
#
# Usage:
#   setup-zig.sh --resolve-only   Print outputs without installing
#   setup-zig.sh                  Resolve and install

set -euo pipefail

MODE="install"
if [[ "${1:-}" == "--resolve-only" ]]; then
    MODE="resolve"
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,18p' "$0"
    exit 0
elif [[ -n "${1:-}" ]]; then
    echo "::error::unknown argument: $1"
    exit 2
fi

INSTALL_DIR="${ZIG_INSTALL_DIR:-$HOME/zig}"
TARGET="${ZIG_TARGET:-x86_64-linux}"
REQUESTED="${ZIG_VERSION:-from-zon}"

zon_version() {
    sed -nE 's/.*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon | head -n 1
}

emit_outputs() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "version=$RESOLVED_VERSION"
            echo "url=$DOWNLOAD_URL"
            echo "target=$TARGET"
            echo "install_dir=$INSTALL_DIR"
        } >> "$GITHUB_OUTPUT"
    fi
}

resolve_from_index() {
    local index_json requested version url
    requested="$1"
    index_json=$(curl -fsSL https://ziglang.org/download/index.json)

    case "$requested" in
        ""|"auto"|"from-zon")
            version=$(zon_version)
            ;;
        "latest"|"stable")
            version=$(echo "$index_json" | jq -r --arg target "$TARGET" '
                to_entries
                | map(select(.key != "master" and .value[$target] != null))
                | sort_by(.key | split(".") | map(tonumber))
                | last
                | .key
            ')
            ;;
        "master"|"nightly")
            RESOLVED_VERSION=$(echo "$index_json" | jq -r '.master.version')
            DOWNLOAD_URL=$(echo "$index_json" | jq -r --arg target "$TARGET" '.master[$target].tarball // empty')
            return
            ;;
        *)
            version="$requested"
            ;;
    esac

    if [[ -z "$version" || "$version" == "null" ]]; then
        echo "::error::could not resolve Zig version from request '$requested'"
        exit 1
    fi

    url=$(echo "$index_json" | jq -r --arg version "$version" --arg target "$TARGET" '.[$version][$target].tarball // empty')
    if [[ -z "$url" || "$url" == "null" ]]; then
        echo "::error::no Zig tarball for version '$version' and target '$TARGET'"
        exit 1
    fi

    RESOLVED_VERSION="$version"
    DOWNLOAD_URL="$url"
}

if [[ -n "${ZIG_DOWNLOAD_URL:-}" ]]; then
    RESOLVED_VERSION="$REQUESTED"
    if [[ "$RESOLVED_VERSION" == "from-zon" || "$RESOLVED_VERSION" == "auto" || -z "$RESOLVED_VERSION" ]]; then
        RESOLVED_VERSION=$(zon_version)
    fi
    DOWNLOAD_URL="$ZIG_DOWNLOAD_URL"
else
    resolve_from_index "$REQUESTED"
fi

echo "Zig request: $REQUESTED"
echo "Zig resolved: $RESOLVED_VERSION ($TARGET)"
echo "Zig URL: $DOWNLOAD_URL"
emit_outputs

if [[ "$MODE" == "resolve" ]]; then
    exit 0
fi

if [[ -x "$INSTALL_DIR/zig" ]]; then
    installed=$("$INSTALL_DIR/zig" version 2>/dev/null || true)
    if [[ "$installed" == "$RESOLVED_VERSION" ]]; then
        echo "Zig $RESOLVED_VERSION already installed"
        echo "$INSTALL_DIR" >> "$GITHUB_PATH"
        exit 0
    fi
    echo "Cached Zig version '$installed' does not match '$RESOLVED_VERSION'; replacing cache"
    rm -rf "$INSTALL_DIR"
fi

mkdir -p "$INSTALL_DIR"
curl -fsSL "$DOWNLOAD_URL" | tar -xJ --strip-components=1 -C "$INSTALL_DIR"

echo "$INSTALL_DIR" >> "$GITHUB_PATH"
"$INSTALL_DIR/zig" version
