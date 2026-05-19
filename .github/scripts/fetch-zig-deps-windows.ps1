#requires -Version 7.0
# Fetch Zig package dependencies on Windows with bounded retry.

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $Command,

    [ValidateRange(1, 10)]
    [int] $Attempts = 4,

    [ValidateRange(1, 300)]
    [int] $InitialDelaySeconds = 10
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function TestTransientFetchFailure([string] $Output) {
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

function ResetZigFetchState {
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

    if ($attempt -ge $Attempts -or -not (TestTransientFetchFailure $text)) {
        Write-Host "Zig dependency fetch failed with exit code $exitCode."
        exit $exitCode
    }

    ResetZigFetchState

    $delay = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), 120)
    Write-Warning "Transient Zig dependency fetch failure detected; retrying in $delay seconds."
    Start-Sleep -Seconds $delay
}

exit $exitCode
