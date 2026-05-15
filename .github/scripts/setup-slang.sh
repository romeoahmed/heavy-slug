#!/usr/bin/env bash
# Resolve, download, and configure Slang for CI.
#
# Environment:
#   SLANG_VERSION       — latest | explicit version/tag (default: latest)
#   SLANG_PLATFORM      — release asset platform (default: inferred from runner)
#   SLANG_ASSET_PATTERN — optional release asset regex override
#   SLANG_DOWNLOAD_URL  — optional pre-resolved tarball URL
#   SLANG_INSTALL_DIR   — extraction target (default: ~/slang)
#   GH_TOKEN            — optional GitHub token for API requests
#   GITHUB_PATH         — GitHub Actions PATH file
#   GITHUB_OUTPUT       — GitHub Actions step output file
#
# Usage:
#   setup-slang.sh --resolve-only   Print outputs without installing
#   setup-slang.sh                  Resolve and install

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

INSTALL_DIR="${SLANG_INSTALL_DIR:-$HOME/slang}"
REQUESTED="${SLANG_VERSION:-latest}"

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

infer_platform() {
    local os arch
    os="$(lower "${RUNNER_OS:-$(uname -s)}")"
    arch="$(lower "${RUNNER_ARCH:-$(uname -m)}")"

    case "$os" in
        linux) os="linux" ;;
        macos|darwin) os="macos" ;;
        windows|mingw*|msys*) os="windows" ;;
        *)
            echo "::error::cannot infer Slang platform for OS '$os'; set SLANG_PLATFORM"
            exit 1
            ;;
    esac

    case "$arch" in
        x64|x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *)
            echo "::error::cannot infer Slang platform for arch '$arch'; set SLANG_PLATFORM"
            exit 1
            ;;
    esac

    printf '%s-%s\n' "$os" "$arch"
}

PLATFORM="${SLANG_PLATFORM:-$(infer_platform)}"
ASSET_PATTERN="${SLANG_ASSET_PATTERN:-}"

version_from_url() {
    local base prefix suffix
    base="${1##*/}"
    prefix="slang-"
    suffix="-${PLATFORM}.tar.gz"
    if [[ "$base" == "$prefix"*"$suffix" ]]; then
        base="${base#"$prefix"}"
        printf '%s\n' "${base%"$suffix"}"
    fi
}

github_api() {
    local url="$1"
    if [[ -n "${GH_TOKEN:-}" ]]; then
        curl -fsSL \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$url"
    else
        curl -fsSL "$url"
    fi
}

emit_outputs() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "version=$RESOLVED_VERSION"
            echo "url=$DOWNLOAD_URL"
            echo "platform=$PLATFORM"
            echo "install_dir=$INSTALL_DIR"
        } >> "$GITHUB_OUTPUT"
    fi
}

resolve_release() {
    local requested release_json tag asset_url
    requested="$1"

    if [[ "$requested" == "" || "$requested" == "latest" || "$requested" == "auto" ]]; then
        release_json=$(github_api "https://api.github.com/repos/shader-slang/slang/releases/latest")
    else
        tag="${requested#v}"
        release_json=$(github_api "https://api.github.com/repos/shader-slang/slang/releases/tags/v${tag}" || true)
        if [[ -z "$release_json" ]]; then
            release_json=$(github_api "https://api.github.com/repos/shader-slang/slang/releases/tags/${requested}")
        fi
    fi

    RESOLVED_VERSION=$(echo "$release_json" | jq -r '.tag_name | ltrimstr("v")')
    if [[ -n "$ASSET_PATTERN" ]]; then
        asset_url=$(echo "$release_json" | jq -r --arg pattern "$ASSET_PATTERN" '
            .assets[]
            | select(.name | test($pattern))
            | .browser_download_url
        ' | head -n 1)
    else
        asset_url=$(echo "$release_json" | jq -r --arg name "slang-${RESOLVED_VERSION}-${PLATFORM}.tar.gz" '
            .assets[]
            | select(.name == $name)
            | .browser_download_url
        ' | head -n 1)
    fi

    if [[ -z "$RESOLVED_VERSION" || "$RESOLVED_VERSION" == "null" ]]; then
        echo "::error::could not resolve Slang version from request '$requested'"
        exit 1
    fi
    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        if [[ -n "$ASSET_PATTERN" ]]; then
            echo "::error::no Slang release asset matched '$ASSET_PATTERN' for '$RESOLVED_VERSION'"
        else
            echo "::error::no Slang release asset named 'slang-${RESOLVED_VERSION}-${PLATFORM}.tar.gz'"
        fi
        echo "Available assets:"
        echo "$release_json" | jq -r '.assets[].name'
        exit 1
    fi

    DOWNLOAD_URL="$asset_url"
}

if [[ -n "${SLANG_DOWNLOAD_URL:-}" ]]; then
    RESOLVED_VERSION="${REQUESTED#v}"
    if [[ "$RESOLVED_VERSION" == "" || "$RESOLVED_VERSION" == "latest" || "$RESOLVED_VERSION" == "auto" ]]; then
        RESOLVED_VERSION=$(version_from_url "$SLANG_DOWNLOAD_URL")
    fi
    if [[ -z "$RESOLVED_VERSION" ]]; then
        echo "::error::could not infer Slang version from URL '$SLANG_DOWNLOAD_URL'; set SLANG_VERSION to the resolved version"
        exit 1
    fi
    DOWNLOAD_URL="$SLANG_DOWNLOAD_URL"
else
    resolve_release "$REQUESTED"
fi

echo "Slang request: $REQUESTED"
echo "Slang resolved: $RESOLVED_VERSION ($PLATFORM)"
echo "Slang URL: $DOWNLOAD_URL"
emit_outputs

if [[ "$MODE" == "resolve" ]]; then
    exit 0
fi

if [[ -x "$INSTALL_DIR/bin/slangc" && -f "$INSTALL_DIR/.slang-version" ]]; then
    installed=$(cat "$INSTALL_DIR/.slang-version")
    if [[ "$installed" == "$RESOLVED_VERSION" ]]; then
        echo "Slang $RESOLVED_VERSION already installed"
        echo "$INSTALL_DIR/bin" >> "$GITHUB_PATH"
        "$INSTALL_DIR/bin/slangc" -v
        exit 0
    fi
    echo "Cached Slang version '$installed' does not match '$RESOLVED_VERSION'; replacing cache"
    rm -rf "$INSTALL_DIR"
fi

mkdir -p "$INSTALL_DIR"
curl -fsSL "$DOWNLOAD_URL" | tar -xz -C "$INSTALL_DIR"

if [[ ! -x "$INSTALL_DIR/bin/slangc" ]]; then
    echo "::error::slangc not found at $INSTALL_DIR/bin/slangc after extraction"
    find "$INSTALL_DIR" -maxdepth 2 -type f | sort
    exit 1
fi

echo "$RESOLVED_VERSION" > "$INSTALL_DIR/.slang-version"
echo "$INSTALL_DIR/bin" >> "$GITHUB_PATH"
"$INSTALL_DIR/bin/slangc" -v
