#!/usr/bin/env bash
# Resolve, cache, and install Zig for POSIX GitHub Actions runners.

set -euo pipefail

mode="install"
case "${1:-}" in
    "")
        ;;
    "--resolve-only")
        mode="resolve"
        ;;
    "-h"|"--help")
        sed -n '1,38p' "$0"
        exit 0
        ;;
    *)
        echo "::error::unknown argument: $1" >&2
        exit 2
        ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
tool_root="${HEAVY_SLUG_TOOL_ROOT:-$HOME/.cache/heavy-slug/toolchains}"
requested="${ZIG_VERSION:-from-zon}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "::error::$1 is required by setup-zig.sh" >&2
        exit 1
    fi
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

zon_version() {
    awk -F '"' '/\.minimum_zig_version[[:space:]]*=/ { print $2; exit }' "$repo_root/build.zig.zon"
}

infer_target() {
    local os arch
    os="$(lower "${RUNNER_OS:-$(uname -s)}")"
    arch="$(lower "${RUNNER_ARCH:-$(uname -m)}")"

    case "$os" in
        linux) os="linux" ;;
        macos|darwin) os="macos" ;;
        *)
            echo "::error::cannot infer Zig target for OS '$os'; set ZIG_TARGET" >&2
            exit 1
            ;;
    esac

    case "$arch" in
        x64|x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        x86|i386|i686) arch="x86" ;;
        *)
            echo "::error::cannot infer Zig target for architecture '$arch'; set ZIG_TARGET" >&2
            exit 1
            ;;
    esac

    printf '%s-%s\n' "$arch" "$os"
}

version_from_url() {
    local base prefix suffix
    base="${1##*/}"
    prefix="zig-${target}-"
    suffix=".tar.xz"
    if [[ "$base" == "$prefix"*"$suffix" ]]; then
        base="${base#"$prefix"}"
        printf '%s\n' "${base%"$suffix"}"
    fi
}

emit_output() {
    local name="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
    fi
}

append_path() {
    if [[ -n "${GITHUB_PATH:-}" ]]; then
        printf '%s\n' "$1" >> "$GITHUB_PATH"
    fi
}

download() {
    local url="$1"
    local output="$2"
    curl --fail --show-error --silent --location --retry 3 --retry-delay 2 --output "$output" "$url"
}

resolve_from_index() {
    local request="$1"
    local index_json version
    index_json="$(curl --fail --show-error --silent --location --retry 3 --retry-delay 2 https://ziglang.org/download/index.json)"

    case "$request" in
        ""|"auto"|"from-zon")
            version="$(zon_version)"
            ;;
        "latest"|"stable")
            version="$(
                jq -r --arg target "$target" '
                    to_entries
                    | map(select(.key != "master" and .value[$target] != null))
                    | sort_by(.key | split(".") | map(tonumber))
                    | last
                    | .key
                ' <<< "$index_json"
            )"
            ;;
        "master"|"nightly")
            resolved_version="$(jq -r '.master.version' <<< "$index_json")"
            download_url="$(jq -r --arg target "$target" '.master[$target].tarball // empty' <<< "$index_json")"
            download_sha256="$(jq -r --arg target "$target" '.master[$target].shasum // empty' <<< "$index_json")"
            return
            ;;
        *)
            version="$request"
            ;;
    esac

    if [[ -z "$version" || "$version" == "null" ]]; then
        echo "::error::could not resolve Zig version from request '$request'" >&2
        exit 1
    fi

    resolved_version="$version"
    download_url="$(jq -r --arg version "$version" --arg target "$target" '.[$version][$target].tarball // empty' <<< "$index_json")"
    download_sha256="$(jq -r --arg version "$version" --arg target "$target" '.[$version][$target].shasum // empty' <<< "$index_json")"
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    if [[ -z "$expected" ]]; then
        return
    fi
    actual="$(shasum -a 256 "$file" | awk '{ print $1 }')"
    if [[ "$actual" != "$expected" ]]; then
        echo "::error::Zig archive checksum mismatch: expected $expected, got $actual" >&2
        exit 1
    fi
}

require_command curl
require_command jq
require_command tar
require_command shasum

target="${ZIG_TARGET:-$(infer_target)}"

if [[ -n "${ZIG_DOWNLOAD_URL:-}" ]]; then
    download_url="$ZIG_DOWNLOAD_URL"
    download_sha256="${ZIG_DOWNLOAD_SHA256:-}"
    resolved_version="${requested#v}"
    case "$resolved_version" in
        ""|"auto"|"from-zon")
            resolved_version="$(zon_version)"
            ;;
        "latest"|"stable"|"master"|"nightly")
            resolved_version="$(version_from_url "$download_url")"
            ;;
    esac
else
    resolve_from_index "$requested"
fi

if [[ -z "${resolved_version:-}" || -z "${download_url:-}" ]]; then
    echo "::error::Zig resolution produced an empty version or URL" >&2
    exit 1
fi

install_dir="${ZIG_INSTALL_DIR:-$tool_root/zig/$target-$resolved_version}"

echo "Zig request: $requested"
echo "Zig resolved: $resolved_version ($target)"
echo "Zig install: $install_dir"

emit_output "version" "$resolved_version"
emit_output "target" "$target"
emit_output "url" "$download_url"
emit_output "sha256" "${download_sha256:-}"
emit_output "install_dir" "$install_dir"

if [[ "$mode" == "resolve" ]]; then
    exit 0
fi

zig_bin="$install_dir/zig"
if [[ -x "$zig_bin" ]]; then
    installed="$("$zig_bin" version 2>/dev/null || true)"
    if [[ "$installed" == "$resolved_version" ]]; then
        append_path "$install_dir"
        "$zig_bin" version
        exit 0
    fi
    echo "Replacing stale Zig install '$installed'"
    rm -rf "$install_dir"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
archive="$tmp_dir/zig.tar.xz"

download "$download_url" "$archive"
verify_sha256 "$archive" "${download_sha256:-}"

mkdir -p "$install_dir"
tar -xJf "$archive" --strip-components=1 -C "$install_dir"

append_path "$install_dir"
"$zig_bin" version
