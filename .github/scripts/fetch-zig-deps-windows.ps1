#requires -Version 7.0
# Fetch Zig package dependencies on Windows with retry for transient network or
# archive-unpack failures. Keep retries scoped to dependency acquisition so
# compile/test failures remain direct and actionable.
#
# Usage:
#   fetch-zig-deps-windows.ps1 -Command "zig build test -Dvulkan=true --fetch=needed"

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $Command,

    [int] $Attempts = 4,
    [int] $InitialDelaySeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Is-TransientFetchFailure([string]$Output) {
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
        'temporarily unavailable'
    )

    foreach ($pattern in $patterns) {
        if ($Output -match [Regex]::Escape($pattern)) {
            return $true
        }
    }
    return $false
}

function Reset-ZigFetchState {
    $paths = @(
        $env:ZIG_GLOBAL_CACHE_DIR,
        (Join-Path $env:TEMP 'zig-cache'),
        (Join-Path $env:TEMP 'zig-cache-tmp')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($path in $paths) {
        if (-not (Test-Path -Path $path)) { continue }
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-Host "Cleared Zig fetch path: $path"
        } catch {
            Write-Warning "Could not clear Zig fetch path '$path': $($_.Exception.Message)"
        }
    }
}

if ($Attempts -lt 1) {
    throw 'Attempts must be at least 1.'
}

$exitCode = 1
for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
    Write-Host "Fetching Zig dependencies, attempt ${attempt}/${Attempts}: $Command"

    $output = & cmd.exe /d /s /c $Command 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if (-not [string]::IsNullOrEmpty($text)) {
        Write-Host $text
    }

    if ($exitCode -eq 0) {
        exit 0
    }

    if ($attempt -ge $Attempts -or -not (Is-TransientFetchFailure $text)) {
        Write-Host "Zig dependency fetch failed with exit code $exitCode."
        exit $exitCode
    }

    Reset-ZigFetchState

    $delay = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), 120)
    Write-Warning "Transient Zig dependency fetch failure detected; retrying in $delay seconds."
    Start-Sleep -Seconds $delay
}

exit $exitCode
