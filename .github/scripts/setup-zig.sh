#!/usr/bin/env bash
# Resolve, download, and configure Zig for CI.
#
# Environment:
#   ZIG_VERSION       — from-zon | stable | latest | master | explicit version
#                       (default: from-zon)
#   ZIG_TARGET        — Zig download target (default: inferred from runner)
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
REQUESTED="${ZIG_VERSION:-from-zon}"

zon_version() {
    sed -nE 's/.*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon | head -n 1
}

version_from_url() {
    local base prefix suffix
    base="${1##*/}"
    prefix="zig-${TARGET}-"
    suffix=".tar.xz"
    if [[ "$base" == "$prefix"*"$suffix" ]]; then
        base="${base#"$prefix"}"
        printf '%s\n' "${base%"$suffix"}"
    fi
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

infer_target() {
    local os arch
    os="$(lower "${RUNNER_OS:-$(uname -s)}")"
    arch="$(lower "${RUNNER_ARCH:-$(uname -m)}")"

    case "$os" in
        linux) os="linux" ;;
        macos|darwin) os="macos" ;;
        windows|mingw*|msys*) os="windows" ;;
        *)
            echo "::error::cannot infer Zig target for OS '$os'; set ZIG_TARGET"
            exit 1
            ;;
    esac

    case "$arch" in
        x64|x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        x86|i386|i686) arch="x86" ;;
        *)
            echo "::error::cannot infer Zig target for arch '$arch'; set ZIG_TARGET"
            exit 1
            ;;
    esac

    printf '%s-%s\n' "$arch" "$os"
}

TARGET="${ZIG_TARGET:-$(infer_target)}"

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
    elif [[ "$RESOLVED_VERSION" == "latest" || "$RESOLVED_VERSION" == "stable" || "$RESOLVED_VERSION" == "master" || "$RESOLVED_VERSION" == "nightly" ]]; then
        RESOLVED_VERSION=$(version_from_url "$ZIG_DOWNLOAD_URL")
    fi
    if [[ -z "$RESOLVED_VERSION" ]]; then
        echo "::error::could not infer Zig version from URL '$ZIG_DOWNLOAD_URL'; set ZIG_VERSION to the resolved version"
        exit 1
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
