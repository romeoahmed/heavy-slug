#requires -Version 7.0
# Resolve, download, and configure Zig for Windows CI.
#
# Environment:
#   ZIG_VERSION       - from-zon | stable/latest | master | explicit version
#                       (default: from-zon)
#   ZIG_TARGET        - Zig download target (default: inferred from runner)
#   ZIG_DOWNLOAD_URL  - optional pre-resolved archive URL
#   ZIG_INSTALL_DIR   - extraction target (default: ~/zig)
#   GITHUB_PATH       - GitHub Actions PATH file
#   GITHUB_OUTPUT     - GitHub Actions step output file
#
# Usage:
#   setup-zig.ps1 --resolve-only
#   setup-zig.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $true
}

$Mode = 'install'
if ($args.Count -gt 1) {
    Write-Error "unknown arguments: $($args -join ' ')"
    exit 2
}
if ($args.Count -eq 1) {
    switch ($args[0]) {
        '--resolve-only' { $Mode = 'resolve' }
        '-h' {
            Get-Content -Path $PSCommandPath -TotalCount 18
            exit 0
        }
        '--help' {
            Get-Content -Path $PSCommandPath -TotalCount 18
            exit 0
        }
        default {
            Write-Error "unknown argument: $($args[0])"
            exit 2
        }
    }
}

function Repo-Root {
    return (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}

function Home-Dir {
    if ($HOME) { return $HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return [Environment]::GetFolderPath('UserProfile')
}

function Zon-Version {
    $zon = Join-Path (Repo-Root) 'build.zig.zon'
    foreach ($line in Get-Content -Path $zon) {
        if ($line -match '\.minimum_zig_version\s*=\s*"([^"]+)"') {
            return $Matches[1]
        }
    }
    throw 'could not read minimum_zig_version from build.zig.zon'
}

function Lower([string]$Value) {
    return $Value.ToLowerInvariant()
}

function Infer-Target {
    $os = Lower ($(if ($env:RUNNER_OS) { $env:RUNNER_OS } else { [System.Runtime.InteropServices.RuntimeInformation]::OSDescription }))
    $arch = Lower ($(if ($env:RUNNER_ARCH) { $env:RUNNER_ARCH } else { [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }))

    if ($os -match 'windows') {
        $os = 'windows'
    } else {
        throw "cannot infer Zig target for OS '$os'; set ZIG_TARGET"
    }

    switch ($arch) {
        { $_ -in @('x64', 'x86_64', 'amd64') } { $arch = 'x86_64'; break }
        { $_ -in @('arm64', 'aarch64') } { $arch = 'aarch64'; break }
        { $_ -in @('x86', 'i386', 'i686') } { $arch = 'x86'; break }
        default { throw "cannot infer Zig target for arch '$arch'; set ZIG_TARGET" }
    }

    return "$arch-$os"
}

function Version-From-Url([string]$Url, [string]$Target) {
    $base = Split-Path -Leaf ([Uri]$Url).AbsolutePath
    $escaped = [Regex]::Escape($Target)
    if ($base -match "^zig-$escaped-(.+)\.(zip|tar\.xz)$") {
        return $Matches[1]
    }
    return $null
}

function Get-PropertyValue($Object, [string]$Name) {
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Resolve-From-Index([string]$Requested, [string]$Target) {
    $index = Invoke-RestMethod -Uri 'https://ziglang.org/download/index.json'

    switch ($Requested) {
        { $_ -in @('', 'auto', 'from-zon') } {
            $version = Zon-Version
            break
        }
        { $_ -in @('latest', 'stable') } {
            $versions = foreach ($prop in $index.PSObject.Properties) {
                if ($prop.Name -eq 'master') { continue }
                if ($null -eq (Get-PropertyValue $prop.Value $Target)) { continue }
                try {
                    [pscustomobject]@{
                        Name = $prop.Name
                        Version = [Version]$prop.Name
                    }
                } catch {
                    continue
                }
            }
            $version = ($versions | Sort-Object Version | Select-Object -Last 1).Name
            break
        }
        { $_ -in @('master', 'nightly') } {
            $master = Get-PropertyValue $index 'master'
            $targetInfo = Get-PropertyValue $master $Target
            if ($null -eq $targetInfo) { throw "no Zig archive for master and target '$Target'" }
            return @{
                Version = $master.version
                Url = $targetInfo.tarball
            }
        }
        default {
            $version = $Requested
        }
    }

    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "could not resolve Zig version from request '$Requested'"
    }

    $versionInfo = Get-PropertyValue $index $version
    $targetInfo = if ($null -ne $versionInfo) { Get-PropertyValue $versionInfo $Target } else { $null }
    if ($null -eq $targetInfo -or [string]::IsNullOrWhiteSpace($targetInfo.tarball)) {
        throw "no Zig archive for version '$version' and target '$Target'"
    }

    return @{
        Version = $version
        Url = $targetInfo.tarball
    }
}

function Emit-Outputs([string]$Version, [string]$Url, [string]$Target, [string]$InstallDir) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$Version"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "url=$Url"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "target=$Target"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "install_dir=$InstallDir"
    }
}

function Add-To-GitHubPath([string]$Path) {
    if ($env:GITHUB_PATH) {
        Add-Content -Path $env:GITHUB_PATH -Value $Path
    }
}

function Clear-Directory([string]$Path) {
    if (Test-Path -Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Expand-ZigArchive([string]$Archive, [string]$InstallDir) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "zig-extract-$PID"
    Clear-Directory $tempRoot
    try {
        if ($Archive.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
            Expand-Archive -Path $Archive -DestinationPath $tempRoot -Force
        } elseif ($Archive.EndsWith('.tar.xz', [StringComparison]::OrdinalIgnoreCase)) {
            tar -xJf $Archive -C $tempRoot
        } else {
            throw "unsupported Zig archive format: $Archive"
        }

        $zigExe = Get-ChildItem -Path $tempRoot -Filter 'zig.exe' -Recurse -File |
            Select-Object -First 1
        if ($null -eq $zigExe) {
            throw 'zig.exe not found after extraction'
        }

        $root = $zigExe.Directory.FullName
        Clear-Directory $InstallDir
        Copy-Item -Path (Join-Path $root '*') -Destination $InstallDir -Recurse -Force
    } finally {
        if (Test-Path -Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
    }
}

$InstallDir = if ($env:ZIG_INSTALL_DIR) { $env:ZIG_INSTALL_DIR } else { Join-Path (Home-Dir) 'zig' }
$Requested = if ($env:ZIG_VERSION) { $env:ZIG_VERSION } else { 'from-zon' }
$Target = if ($env:ZIG_TARGET) { $env:ZIG_TARGET } else { Infer-Target }

if ($env:ZIG_DOWNLOAD_URL) {
    $ResolvedVersion = $Requested
    if ($ResolvedVersion -in @('', 'auto', 'from-zon')) {
        $ResolvedVersion = Zon-Version
    } elseif ($ResolvedVersion -in @('latest', 'stable', 'master', 'nightly')) {
        $ResolvedVersion = Version-From-Url $env:ZIG_DOWNLOAD_URL $Target
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedVersion)) {
        throw "could not infer Zig version from URL '$env:ZIG_DOWNLOAD_URL'; set ZIG_VERSION to the resolved version"
    }
    $DownloadUrl = $env:ZIG_DOWNLOAD_URL
} else {
    $resolved = Resolve-From-Index $Requested $Target
    $ResolvedVersion = $resolved.Version
    $DownloadUrl = $resolved.Url
}

Write-Host "Zig request: $Requested"
Write-Host "Zig resolved: $ResolvedVersion ($Target)"
Write-Host "Zig URL: $DownloadUrl"
Emit-Outputs $ResolvedVersion $DownloadUrl $Target $InstallDir

if ($Mode -eq 'resolve') {
    exit 0
}

$ZigExe = Join-Path $InstallDir 'zig.exe'
if (Test-Path -Path $ZigExe) {
    $installed = & $ZigExe version
    if ($installed -eq $ResolvedVersion) {
        Write-Host "Zig $ResolvedVersion already installed"
        Add-To-GitHubPath $InstallDir
        exit 0
    }
    Write-Host "Cached Zig version '$installed' does not match '$ResolvedVersion'; replacing cache"
    Remove-Item -Path $InstallDir -Recurse -Force
}

$archive = Join-Path ([IO.Path]::GetTempPath()) (Split-Path -Leaf ([Uri]$DownloadUrl).AbsolutePath)
Invoke-WebRequest -Uri $DownloadUrl -OutFile $archive
try {
    Expand-ZigArchive $archive $InstallDir
} finally {
    if (Test-Path -Path $archive) {
        Remove-Item -Path $archive -Force
    }
}

Add-To-GitHubPath $InstallDir
& (Join-Path $InstallDir 'zig.exe') version
