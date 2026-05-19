#!/usr/bin/env bash
# Resolve, cache, and install Slang for POSIX GitHub Actions runners.

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

tool_root="${HEAVY_SLUG_TOOL_ROOT:-$HOME/.cache/heavy-slug/toolchains}"
requested="${SLANG_VERSION:-2026.9}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "::error::$1 is required by setup-slang.sh" >&2
        exit 1
    fi
}

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
        *)
            echo "::error::cannot infer Slang platform for OS '$os'; set SLANG_PLATFORM" >&2
            exit 1
            ;;
    esac

    case "$arch" in
        x64|x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *)
            echo "::error::cannot infer Slang platform for architecture '$arch'; set SLANG_PLATFORM" >&2
            exit 1
            ;;
    esac

    printf '%s-%s\n' "$os" "$arch"
}

version_from_url() {
    local base escaped
    base="${1##*/}"
    escaped="${platform//./\\.}"
    if [[ "$base" =~ ^slang-(.+)-${escaped}\.(tar\.gz|zip)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$base" =~ ^slang-(.+)-${escaped}-glibc-[0-9.]+\.zip$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
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

github_api() {
    local url="$1"
    if [[ -n "${GH_TOKEN:-}" ]]; then
        curl --fail --show-error --silent --location --retry 3 --retry-delay 2 \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$url"
    else
        curl --fail --show-error --silent --location --retry 3 --retry-delay 2 "$url"
    fi
}

resolve_release() {
    local request="$1"
    local release_json asset_url tag

    if [[ "$request" == "" || "$request" == "latest" || "$request" == "auto" ]]; then
        release_json="$(github_api "https://api.github.com/repos/shader-slang/slang/releases/latest")"
    else
        tag="${request#v}"
        if ! release_json="$(github_api "https://api.github.com/repos/shader-slang/slang/releases/tags/v${tag}" 2>/dev/null)"; then
            release_json="$(github_api "https://api.github.com/repos/shader-slang/slang/releases/tags/${request}")"
        fi
    fi

    resolved_version="$(jq -r '.tag_name | ltrimstr("v")' <<< "$release_json")"
    if [[ -z "$resolved_version" || "$resolved_version" == "null" ]]; then
        echo "::error::could not resolve Slang version from request '$request'" >&2
        exit 1
    fi

    if [[ -n "${SLANG_ASSET_PATTERN:-}" ]]; then
        asset_url="$(
            jq -r --arg pattern "$SLANG_ASSET_PATTERN" '
                first(.assets[] | select(.name | test($pattern)) | .browser_download_url) // empty
            ' <<< "$release_json"
        )"
    else
        asset_url="$(
            jq -r --arg version "$resolved_version" --arg platform "$platform" '
                first(
                    .assets[]
                    | select(
                        .name == "slang-\($version)-\($platform).tar.gz" or
                        .name == "slang-\($version)-\($platform).zip" or
                        ((.name | startswith("slang-\($version)-\($platform)-glibc-")) and (.name | endswith(".zip")))
                    )
                    | .browser_download_url
                ) // empty
            ' <<< "$release_json"
        )"
    fi

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo "::error::no Slang release asset found for $resolved_version on $platform" >&2
        echo "Available Slang assets:" >&2
        jq -r '.assets[].name' <<< "$release_json" >&2
        exit 1
    fi

    download_url="$asset_url"
}

extract_archive() {
    local archive="$1"
    local temp_root slangc_path bin_dir root_dir
    temp_root="$(mktemp -d)"

    case "$archive" in
        *.tar.gz)
            tar -xzf "$archive" -C "$temp_root"
            ;;
        *.zip)
            require_command unzip
            unzip -q "$archive" -d "$temp_root"
            ;;
        *)
            echo "::error::unsupported Slang archive format: $archive" >&2
            exit 1
            ;;
    esac

    slangc_path="$(find "$temp_root" -type f \( -name slangc -o -name slangc.exe \) -print -quit)"
    if [[ -z "$slangc_path" ]]; then
        echo "::error::slangc not found after Slang extraction" >&2
        find "$temp_root" -maxdepth 3 -type f | sort >&2
        exit 1
    fi

    bin_dir="$(dirname "$slangc_path")"
    if [[ "$(basename "$bin_dir")" == "bin" ]]; then
        root_dir="$(dirname "$bin_dir")"
    else
        root_dir="$bin_dir"
    fi

    rm -rf "$install_dir"
    mkdir -p "$install_dir"
    cp -R "$root_dir"/. "$install_dir"
    rm -rf "$temp_root"
}

require_command curl
require_command jq
require_command tar

platform="${SLANG_PLATFORM:-$(infer_platform)}"

if [[ -n "${SLANG_DOWNLOAD_URL:-}" ]]; then
    download_url="$SLANG_DOWNLOAD_URL"
    resolved_version="${requested#v}"
    case "$resolved_version" in
        ""|"auto"|"latest")
            resolved_version="$(version_from_url "$download_url")"
            ;;
    esac
else
    resolve_release "$requested"
fi

if [[ -z "${resolved_version:-}" || -z "${download_url:-}" ]]; then
    echo "::error::Slang resolution produced an empty version or URL" >&2
    exit 1
fi

install_dir="${SLANG_INSTALL_DIR:-$tool_root/slang/$platform-$resolved_version}"

echo "Slang request: $requested"
echo "Slang resolved: $resolved_version ($platform)"
echo "Slang install: $install_dir"

emit_output "version" "$resolved_version"
emit_output "platform" "$platform"
emit_output "url" "$download_url"
emit_output "install_dir" "$install_dir"

if [[ "$mode" == "resolve" ]]; then
    exit 0
fi

slangc="$install_dir/bin/slangc"
version_file="$install_dir/.slang-version"
if [[ -x "$slangc" && -f "$version_file" ]]; then
    installed="$(tr -d '[:space:]' < "$version_file")"
    if [[ "$installed" == "$resolved_version" ]]; then
        append_path "$install_dir/bin"
        "$slangc" -v
        exit 0
    fi
    echo "Replacing stale Slang install '$installed'"
    rm -rf "$install_dir"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
archive="$tmp_dir/$(basename "$download_url")"

download "$download_url" "$archive"
extract_archive "$archive"
printf '%s\n' "$resolved_version" > "$version_file"

append_path "$install_dir/bin"
"$slangc" -v
