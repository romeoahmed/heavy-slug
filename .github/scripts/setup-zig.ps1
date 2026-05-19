#requires -Version 7.0
# Resolve, cache, and install Zig for Windows GitHub Actions runners.

param(
    [switch] $ResolveOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $true
}

function RepoRoot {
    return (Resolve-Path -Path (Join-Path $PSScriptRoot '../..')).Path
}

function HomeDir {
    if ($HOME) { return $HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return [Environment]::GetFolderPath('UserProfile')
}

function Lower([string] $Value) {
    return $Value.ToLowerInvariant()
}

function ZonVersion {
    $zon = Join-Path (RepoRoot) 'build.zig.zon'
    foreach ($line in Get-Content -Path $zon) {
        if ($line -match '\.minimum_zig_version\s*=\s*"([^"]+)"') {
            return $Matches[1]
        }
    }
    throw 'could not read minimum_zig_version from build.zig.zon'
}

function InferTarget {
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
        default { throw "cannot infer Zig target for architecture '$arch'; set ZIG_TARGET" }
    }

    return "$arch-$os"
}

function VersionFromUrl([string] $Url, [string] $Target) {
    $leaf = Split-Path -Leaf ([Uri] $Url).AbsolutePath
    $escaped = [Regex]::Escape($Target)
    if ($leaf -match "^zig-$escaped-(.+)\.(zip|tar\.xz)$") {
        return $Matches[1]
    }
    return $null
}

function PropertyValue($Object, [string] $Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ResolveFromIndex([string] $Requested, [string] $Target) {
    $index = Invoke-RestMethod -Uri 'https://ziglang.org/download/index.json'

    switch ($Requested) {
        { $_ -in @('', 'auto', 'from-zon') } {
            $version = ZonVersion
            break
        }
        { $_ -in @('latest', 'stable') } {
            $versions = foreach ($property in $index.PSObject.Properties) {
                if ($property.Name -eq 'master') { continue }
                if ($null -eq (PropertyValue $property.Value $Target)) { continue }
                try {
                    [pscustomobject]@{
                        Name = $property.Name
                        Version = [Version] $property.Name
                    }
                } catch {
                    continue
                }
            }
            $version = ($versions | Sort-Object -Property Version | Select-Object -Last 1).Name
            break
        }
        { $_ -in @('master', 'nightly') } {
            $master = PropertyValue $index 'master'
            $targetInfo = PropertyValue $master $Target
            if ($null -eq $targetInfo) { throw "no Zig archive for master and target '$Target'" }
            return @{
                Version = $master.version
                Url = $targetInfo.tarball
                Sha256 = $targetInfo.shasum
            }
        }
        default {
            $version = $Requested
        }
    }

    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "could not resolve Zig version from request '$Requested'"
    }

    $versionInfo = PropertyValue $index $version
    $targetInfo = if ($null -ne $versionInfo) { PropertyValue $versionInfo $Target } else { $null }
    if ($null -eq $targetInfo -or [string]::IsNullOrWhiteSpace($targetInfo.tarball)) {
        throw "no Zig archive for version '$version' and target '$Target'"
    }

    return @{
        Version = $version
        Url = $targetInfo.tarball
        Sha256 = $targetInfo.shasum
    }
}

function AddGitHubOutput([string] $Name, [string] $Value) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function AddGitHubPath([string] $Path) {
    if ($env:GITHUB_PATH) {
        Add-Content -Path $env:GITHUB_PATH -Value $Path
    }
}

function ClearDirectory([string] $Path) {
    if (Test-Path -Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function DownloadFile([string] $Url, [string] $Output) {
    Invoke-WebRequest -Uri $Url -OutFile $Output
}

function VerifySha256([string] $Path, [string] $Expected) {
    if ([string]::IsNullOrWhiteSpace($Expected)) { return }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "Zig archive checksum mismatch: expected $Expected, got $actual"
    }
}

function ExpandZigArchive([string] $Archive, [string] $InstallDir) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "zig-extract-$PID"
    ClearDirectory $tempRoot
    try {
        if ($Archive.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
            Expand-Archive -Path $Archive -DestinationPath $tempRoot -Force
        } elseif ($Archive.EndsWith('.tar.xz', [StringComparison]::OrdinalIgnoreCase)) {
            tar -xJf $Archive -C $tempRoot
        } else {
            throw "unsupported Zig archive format: $Archive"
        }

        $zigExe = Get-ChildItem -Path $tempRoot -Filter 'zig.exe' -Recurse -File | Select-Object -First 1
        if ($null -eq $zigExe) {
            throw 'zig.exe not found after Zig extraction'
        }

        ClearDirectory $InstallDir
        Copy-Item -Path (Join-Path $zigExe.Directory.FullName '*') -Destination $InstallDir -Recurse -Force
    } finally {
        if (Test-Path -Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
    }
}

$toolRoot = if ($env:HEAVY_SLUG_TOOL_ROOT) {
    $env:HEAVY_SLUG_TOOL_ROOT
} elseif ($env:HEAVY_SLUG_TOOL_DIR) {
    $env:HEAVY_SLUG_TOOL_DIR
} else {
    Join-Path (HomeDir) '.cache/heavy-slug/toolchains'
}
$requested = if ($env:ZIG_VERSION) { $env:ZIG_VERSION } else { 'from-zon' }
$target = if ($env:ZIG_TARGET) { $env:ZIG_TARGET } else { InferTarget }

if ($env:ZIG_DOWNLOAD_URL) {
    $resolvedVersion = $requested.TrimStart('v')
    if ($resolvedVersion -in @('', 'auto', 'from-zon')) {
        $resolvedVersion = ZonVersion
    } elseif ($resolvedVersion -in @('latest', 'stable', 'master', 'nightly')) {
        $resolvedVersion = VersionFromUrl $env:ZIG_DOWNLOAD_URL $target
    }
    if ([string]::IsNullOrWhiteSpace($resolvedVersion)) {
        throw "could not infer Zig version from URL '$env:ZIG_DOWNLOAD_URL'"
    }
    $downloadUrl = $env:ZIG_DOWNLOAD_URL
    $downloadSha256 = if ($env:ZIG_DOWNLOAD_SHA256) { $env:ZIG_DOWNLOAD_SHA256 } else { '' }
} else {
    $resolved = ResolveFromIndex $requested $target
    $resolvedVersion = $resolved.Version
    $downloadUrl = $resolved.Url
    $downloadSha256 = $resolved.Sha256
}

$installDir = if ($env:ZIG_INSTALL_DIR) {
    $env:ZIG_INSTALL_DIR
} else {
    Join-Path (Join-Path $toolRoot 'zig') "$target-$resolvedVersion"
}

Write-Host "Zig request: $requested"
Write-Host "Zig resolved: $resolvedVersion ($target)"
Write-Host "Zig install: $installDir"

AddGitHubOutput 'version' $resolvedVersion
AddGitHubOutput 'target' $target
AddGitHubOutput 'url' $downloadUrl
AddGitHubOutput 'sha256' $downloadSha256
AddGitHubOutput 'install_dir' $installDir

if ($ResolveOnly) {
    exit 0
}

$zigExe = Join-Path $installDir 'zig.exe'
if (Test-Path -Path $zigExe) {
    $installed = & $zigExe version
    if ($installed -eq $resolvedVersion) {
        AddGitHubPath $installDir
        & $zigExe version
        exit 0
    }
    Write-Host "Replacing stale Zig install '$installed'"
    Remove-Item -Path $installDir -Recurse -Force
}

$archive = Join-Path ([IO.Path]::GetTempPath()) (Split-Path -Leaf ([Uri] $downloadUrl).AbsolutePath)
DownloadFile $downloadUrl $archive
try {
    VerifySha256 $archive $downloadSha256
    ExpandZigArchive $archive $installDir
} finally {
    if (Test-Path -Path $archive) {
        Remove-Item -Path $archive -Force
    }
}

AddGitHubPath $installDir
& $zigExe version
