#requires -Version 7.0
# Prepare Windows GitHub-hosted runners for Zig builds.
#
# Zig's package fetcher extracts source archives into its global cache. Keep
# Windows CI paths short and enable long paths before Zig starts; do not change
# security scanning or protocol policy here.
#
# Usage:
#   prepare-windows-ci.ps1 -CacheName windows-2025-vs2026-core

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $CacheName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $true
}

function Add-GitHubEnv([string]$Name, [string]$Value) {
    if ($env:GITHUB_ENV) {
        Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value"
    }
}

function Add-GitHubOutput([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function Ensure-Directory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path -Path $Path).Path
}

function Enable-LongPaths {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    New-ItemProperty `
        -Path $path `
        -Name 'LongPathsEnabled' `
        -Value 1 `
        -PropertyType DWORD `
        -Force | Out-Null
    git config --global core.longpaths true
}

$root = Ensure-Directory 'D:\a\_hs'
$tools = Ensure-Directory (Join-Path $root 'tools')
$temp = Ensure-Directory (Join-Path $root 'tmp')
$zigGlobal = Ensure-Directory (Join-Path $root 'zg')
$zigLocal = Ensure-Directory (Join-Path (Join-Path $root 'zl') $CacheName)
$zigInstall = Ensure-Directory (Join-Path $tools 'zig')
$slangInstall = Ensure-Directory (Join-Path $tools 'slang')

Enable-LongPaths

Add-GitHubEnv 'TMP' $temp
Add-GitHubEnv 'TEMP' $temp
Add-GitHubEnv 'ZIG_GLOBAL_CACHE_DIR' $zigGlobal
Add-GitHubEnv 'ZIG_LOCAL_CACHE_DIR' $zigLocal
Add-GitHubEnv 'ZIG_INSTALL_DIR' $zigInstall
Add-GitHubEnv 'SLANG_INSTALL_DIR' $slangInstall
Add-GitHubEnv 'GIT_TERMINAL_PROMPT' '0'

Add-GitHubOutput 'root' $root
Add-GitHubOutput 'temp_dir' $temp
Add-GitHubOutput 'zig_global_cache_dir' $zigGlobal
Add-GitHubOutput 'zig_local_cache_dir' $zigLocal
Add-GitHubOutput 'zig_install_dir' $zigInstall
Add-GitHubOutput 'slang_install_dir' $slangInstall

Write-Host "Windows CI root: $root"
Write-Host "ZIG_GLOBAL_CACHE_DIR: $zigGlobal"
Write-Host "ZIG_LOCAL_CACHE_DIR: $zigLocal"
Write-Host "TMP/TEMP: $temp"
