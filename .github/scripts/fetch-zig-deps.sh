#!/usr/bin/env bash
# Prefetch Zig package dependencies with bounded exponential backoff.

set -euo pipefail

attempts="${ZIG_FETCH_ATTEMPTS:-4}"
initial_delay_seconds="${ZIG_FETCH_INITIAL_DELAY_SECONDS:-10}"
max_delay_seconds="${ZIG_FETCH_MAX_DELAY_SECONDS:-120}"

usage() {
    cat <<'EOF'
usage: fetch-zig-deps.sh <zig-build-args...>

Runs `zig build <zig-build-args...> --fetch=needed` with retry for transient
network/archive failures.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

build_args=("$@")
if [[ "${#build_args[@]}" -eq 0 && -n "${ZIG_FETCH_BUILD_ARGS:-}" ]]; then
    read -r -a build_args <<< "$ZIG_FETCH_BUILD_ARGS"
fi

if [[ "${#build_args[@]}" -eq 0 ]]; then
    usage >&2
    exit 2
fi

require_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ || "$value" -lt 1 ]]; then
        echo "::error::$name must be a positive integer" >&2
        exit 2
    fi
}

is_transient_failure() {
    local output
    output="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$output" in
        *httpconnectionclosing* | \
        *"unable to discover remote git server capabilities"* | \
        *"unable to unpack tarball to temporary directory"* | \
        *readfailed* | \
        *"connection reset"* | \
        *"connection was closed"* | \
        *"connection closed"* | \
        *tls* | \
        *"temporarily unavailable"* | \
        *"network is unreachable"* | \
        *"failed to fetch"* | \
        *"502 bad gateway"* | \
        *"503 service unavailable"* | \
        *"504 gateway timeout"* | \
        *timeout*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_safe_cleanup_path() {
    local path="$1"
    if [[ -z "$path" || "$path" == "/" ]]; then
        return 1
    fi
    if [[ -n "${HOME:-}" && ( "$path" == "$HOME" || "$path" == "$HOME/" ) ]]; then
        return 1
    fi
    if [[ -n "${TMPDIR:-}" && ( "$path" == "$TMPDIR" || "$path" == "$TMPDIR/" ) ]]; then
        return 1
    fi
    if [[ "$path" == "/tmp" || "$path" == "/tmp/" ]]; then
        return 1
    fi
    return 0
}

reset_zig_fetch_state() {
    if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
        echo "Skipping Zig cache cleanup outside GitHub Actions."
        return
    fi

    local paths=()
    if [[ -n "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
        paths+=("$ZIG_GLOBAL_CACHE_DIR")
    elif [[ -n "${HOME:-}" ]]; then
        paths+=("$HOME/.cache/zig")
    fi

    local temp_root="${TMPDIR:-/tmp}"
    paths+=("$temp_root/zig-cache" "$temp_root/zig-cache-tmp")

    local path
    for path in "${paths[@]}"; do
        if ! is_safe_cleanup_path "$path" || [[ ! -e "$path" ]]; then
            continue
        fi
        rm -rf -- "$path"
        mkdir -p -- "$path"
        echo "Cleared Zig fetch path: $path"
    done
}

require_integer "ZIG_FETCH_ATTEMPTS" "$attempts"
require_integer "ZIG_FETCH_INITIAL_DELAY_SECONDS" "$initial_delay_seconds"
require_integer "ZIG_FETCH_MAX_DELAY_SECONDS" "$max_delay_seconds"

command=(zig build "${build_args[@]}" --fetch=needed)
exit_code=1

for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    printf 'Fetching Zig dependencies, attempt %d/%d: ' "$attempt" "$attempts"
    printf '%q ' "${command[@]}"
    printf '\n'

    set +e
    output="$("${command[@]}" 2>&1)"
    exit_code="$?"
    set -e

    if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
    fi

    if [[ "$exit_code" -eq 0 ]]; then
        exit 0
    fi

    if [[ "$attempt" -ge "$attempts" ]] || ! is_transient_failure "$output"; then
        echo "Zig dependency fetch failed with exit code $exit_code."
        exit "$exit_code"
    fi

    reset_zig_fetch_state

    delay=$((initial_delay_seconds * (1 << (attempt - 1))))
    if [[ "$delay" -gt "$max_delay_seconds" ]]; then
        delay="$max_delay_seconds"
    fi
    echo "::warning::Transient Zig dependency fetch failure detected; retrying in ${delay}s."
    sleep "$delay"
done

exit "$exit_code"
