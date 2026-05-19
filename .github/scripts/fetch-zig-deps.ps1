#requires -Version 7.0
# Prefetch Zig package dependencies with bounded exponential backoff.

param(
    [ValidateRange(1, 10)]
    [int] $Attempts = 4,

    [ValidateRange(1, 300)]
    [int] $InitialDelaySeconds = 10,

    [ValidateRange(1, 300)]
    [int] $MaxDelaySeconds = 120,

    [string[]] $BuildArgs = @()
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ($BuildArgs.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:ZIG_FETCH_BUILD_ARGS)) {
    $BuildArgs = $env:ZIG_FETCH_BUILD_ARGS.Trim() -split '\s+'
}

if ($BuildArgs.Count -eq 0) {
    Write-Error 'usage: fetch-zig-deps.ps1 <zig-build-args...>'
    exit 2
}

function Test-TransientFetchFailure([string] $Output) {
    $patterns = @(
        'HttpConnectionClosing',
        'unable to discover remote git server capabilities',
        'unable to unpack tarball to temporary directory',
        'ReadFailed',
        'Connection reset',
        'connection was closed',
        'connection closed',
        'TLS',
        'timeout',
        'temporarily unavailable',
        'network is unreachable',
        'failed to fetch',
        '502 Bad Gateway',
        '503 Service Unavailable',
        '504 Gateway Timeout'
    )

    foreach ($pattern in $patterns) {
        if ($Output.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Reset-ZigFetchState {
    if ($env:GITHUB_ACTIONS -ne 'true') {
        Write-Host 'Skipping Zig cache cleanup outside GitHub Actions.'
        return
    }

    $paths = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ZIG_GLOBAL_CACHE_DIR)) {
        $paths += $env:ZIG_GLOBAL_CACHE_DIR
    } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $paths += (Join-Path $env:LOCALAPPDATA 'zig')
    }

    $tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $env:TEMP
    } else {
        [IO.Path]::GetTempPath()
    }
    $paths += (Join-Path $tempRoot 'zig-cache')
    $paths += (Join-Path $tempRoot 'zig-cache-tmp')

    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path -eq '\' -or -not (Test-Path -Path $path)) {
            continue
        }

        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-Host "Cleared Zig fetch path: $path"
        } catch {
            Write-Warning "Could not clear Zig fetch path '$path': $($_.Exception.Message)"
        }
    }
}

$commandForLog = "zig build $($BuildArgs -join ' ') --fetch=needed"
$exitCode = 1

for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
    Write-Host "Fetching Zig dependencies, attempt ${attempt}/${Attempts}: $commandForLog"

    $output = & zig build @BuildArgs --fetch=needed 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if (-not [string]::IsNullOrEmpty($text)) {
        Write-Host $text
    }

    if ($exitCode -eq 0) {
        exit 0
    }

    if ($attempt -ge $Attempts -or -not (Test-TransientFetchFailure $text)) {
        Write-Host "Zig dependency fetch failed with exit code $exitCode."
        exit $exitCode
    }

    Reset-ZigFetchState

    $delay = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), $MaxDelaySeconds)
    Write-Warning "Transient Zig dependency fetch failure detected; retrying in $delay seconds."
    Start-Sleep -Seconds $delay
}

exit $exitCode
