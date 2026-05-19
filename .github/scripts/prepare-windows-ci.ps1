#requires -Version 7.0
# Prepare short, deterministic Windows paths for Zig package extraction.

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $Name
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $true
}

function EnsureDirectory([string] $Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path -Path $Path).Path
}

function AddGitHubEnv([string] $Key, [string] $Value) {
    if ($env:GITHUB_ENV) {
        Add-Content -Path $env:GITHUB_ENV -Value "$Key=$Value"
    }
}

function AddGitHubOutput([string] $Key, [string] $Value) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Key=$Value"
    }
}

function EnableLongPaths {
    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    New-ItemProperty `
        -Path $registryPath `
        -Name 'LongPathsEnabled' `
        -Value 1 `
        -PropertyType DWORD `
        -Force | Out-Null
    git config --global core.longpaths true
}

$root = EnsureDirectory 'D:\a\_hs'
$tools = EnsureDirectory (Join-Path $root 'tools')
$temp = EnsureDirectory (Join-Path $root 'tmp')
$zigGlobal = EnsureDirectory (Join-Path $root 'zg')
$zigLocal = EnsureDirectory (Join-Path (Join-Path $root 'zl') $Name)

EnableLongPaths

AddGitHubEnv 'TMP' $temp
AddGitHubEnv 'TEMP' $temp
AddGitHubEnv 'HEAVY_SLUG_TOOL_DIR' $tools
AddGitHubEnv 'ZIG_GLOBAL_CACHE_DIR' $zigGlobal
AddGitHubEnv 'ZIG_LOCAL_CACHE_DIR' $zigLocal
AddGitHubEnv 'GIT_TERMINAL_PROMPT' '0'

AddGitHubOutput 'root' $root
AddGitHubOutput 'tool_dir' $tools
AddGitHubOutput 'temp_dir' $temp
AddGitHubOutput 'zig_global_cache_dir' $zigGlobal
AddGitHubOutput 'zig_local_cache_dir' $zigLocal

Write-Host "Windows CI root: $root"
Write-Host "Tool directory: $tools"
Write-Host "ZIG_GLOBAL_CACHE_DIR: $zigGlobal"
Write-Host "ZIG_LOCAL_CACHE_DIR: $zigLocal"
Write-Host "TMP/TEMP: $temp"
