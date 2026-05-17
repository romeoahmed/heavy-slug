#requires -Version 7.0
# Resolve, download, and configure Slang for Windows CI.
#
# Environment:
#   SLANG_VERSION       - latest | explicit version/tag (default: latest)
#   SLANG_PLATFORM      - release asset platform (default: inferred from runner)
#   SLANG_ASSET_PATTERN - optional release asset regex override
#   SLANG_DOWNLOAD_URL  - optional pre-resolved archive URL
#   SLANG_INSTALL_DIR   - extraction target (default: ~/slang)
#   GH_TOKEN            - optional GitHub token for API requests
#   GITHUB_PATH         - GitHub Actions PATH file
#   GITHUB_OUTPUT       - GitHub Actions step output file
#
# Usage:
#   setup-slang.ps1 --resolve-only
#   setup-slang.ps1

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

function Home-Dir {
    if ($HOME) { return $HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return [Environment]::GetFolderPath('UserProfile')
}

function Lower([string]$Value) {
    return $Value.ToLowerInvariant()
}

function Infer-Platform {
    $os = Lower ($(if ($env:RUNNER_OS) { $env:RUNNER_OS } else { [System.Runtime.InteropServices.RuntimeInformation]::OSDescription }))
    $arch = Lower ($(if ($env:RUNNER_ARCH) { $env:RUNNER_ARCH } else { [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }))

    if ($os -match 'windows') {
        $os = 'windows'
    } else {
        throw "cannot infer Slang platform for OS '$os'; set SLANG_PLATFORM"
    }

    switch ($arch) {
        { $_ -in @('x64', 'x86_64', 'amd64') } { $arch = 'x86_64'; break }
        { $_ -in @('arm64', 'aarch64') } { $arch = 'aarch64'; break }
        default { throw "cannot infer Slang platform for arch '$arch'; set SLANG_PLATFORM" }
    }

    return "$os-$arch"
}

function Version-From-Url([string]$Url, [string]$Platform) {
    $base = Split-Path -Leaf ([Uri]$Url).AbsolutePath
    $escaped = [Regex]::Escape($Platform)
    if ($base -match "^slang-(.+)-$escaped\.(zip|tar\.gz)$") {
        return $Matches[1]
    }
    return $null
}

function Github-Api([string]$Url) {
    $headers = @{
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GH_TOKEN) {
        $headers['Authorization'] = "Bearer $env:GH_TOKEN"
    }
    return Invoke-RestMethod -Uri $Url -Headers $headers
}

function Resolve-Release([string]$Requested, [string]$Platform, [string]$AssetPattern) {
    if ($Requested -in @('', 'latest', 'auto')) {
        $release = Github-Api 'https://api.github.com/repos/shader-slang/slang/releases/latest'
    } else {
        $tag = $Requested.TrimStart('v')
        try {
            $release = Github-Api "https://api.github.com/repos/shader-slang/slang/releases/tags/v$tag"
        } catch {
            $release = Github-Api "https://api.github.com/repos/shader-slang/slang/releases/tags/$Requested"
        }
    }

    $version = $release.tag_name.TrimStart('v')
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "could not resolve Slang version from request '$Requested'"
    }

    if (-not [string]::IsNullOrWhiteSpace($AssetPattern)) {
        $asset = $release.assets |
            Where-Object { $_.name -match $AssetPattern } |
            Select-Object -First 1
    } else {
        $candidateNames = @(
            "slang-$version-$Platform.zip",
            "slang-$version-$Platform.tar.gz"
        )
        $asset = $release.assets |
            Where-Object { $candidateNames -contains $_.name } |
            Select-Object -First 1
    }

    if ($null -eq $asset -or [string]::IsNullOrWhiteSpace($asset.browser_download_url)) {
        $available = ($release.assets | ForEach-Object { $_.name }) -join ', '
        if ([string]::IsNullOrWhiteSpace($AssetPattern)) {
            throw "no Slang release asset for version '$version' and platform '$Platform'. Available: $available"
        }
        throw "no Slang release asset matched '$AssetPattern' for '$version'. Available: $available"
    }

    return @{
        Version = $version
        Url = $asset.browser_download_url
    }
}

function Emit-Outputs([string]$Version, [string]$Url, [string]$Platform, [string]$InstallDir) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$Version"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "url=$Url"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "platform=$Platform"
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

function Expand-SlangArchive([string]$Archive, [string]$InstallDir) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "slang-extract-$PID"
    Clear-Directory $tempRoot
    try {
        if ($Archive.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
            Expand-Archive -Path $Archive -DestinationPath $tempRoot -Force
        } elseif ($Archive.EndsWith('.tar.gz', [StringComparison]::OrdinalIgnoreCase)) {
            tar -xzf $Archive -C $tempRoot
        } else {
            throw "unsupported Slang archive format: $Archive"
        }

        $slangc = Get-ChildItem -Path $tempRoot -Filter 'slangc.exe' -Recurse -File |
            Select-Object -First 1
        if ($null -eq $slangc) {
            throw 'slangc.exe not found after extraction'
        }

        $root = if ($slangc.Directory.Name -eq 'bin') {
            $slangc.Directory.Parent.FullName
        } else {
            $slangc.Directory.FullName
        }

        Clear-Directory $InstallDir
        Copy-Item -Path (Join-Path $root '*') -Destination $InstallDir -Recurse -Force
    } finally {
        if (Test-Path -Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
    }
}

$InstallDir = if ($env:SLANG_INSTALL_DIR) { $env:SLANG_INSTALL_DIR } else { Join-Path (Home-Dir) 'slang' }
$Requested = if ($env:SLANG_VERSION) { $env:SLANG_VERSION } else { 'latest' }
$Platform = if ($env:SLANG_PLATFORM) { $env:SLANG_PLATFORM } else { Infer-Platform }
$AssetPattern = if ($env:SLANG_ASSET_PATTERN) { $env:SLANG_ASSET_PATTERN } else { '' }

if ($env:SLANG_DOWNLOAD_URL) {
    $ResolvedVersion = $Requested.TrimStart('v')
    if ($ResolvedVersion -in @('', 'latest', 'auto')) {
        $ResolvedVersion = Version-From-Url $env:SLANG_DOWNLOAD_URL $Platform
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedVersion)) {
        throw "could not infer Slang version from URL '$env:SLANG_DOWNLOAD_URL'; set SLANG_VERSION to the resolved version"
    }
    $DownloadUrl = $env:SLANG_DOWNLOAD_URL
} else {
    $resolved = Resolve-Release $Requested $Platform $AssetPattern
    $ResolvedVersion = $resolved.Version
    $DownloadUrl = $resolved.Url
}

Write-Host "Slang request: $Requested"
Write-Host "Slang resolved: $ResolvedVersion ($Platform)"
Write-Host "Slang URL: $DownloadUrl"
Emit-Outputs $ResolvedVersion $DownloadUrl $Platform $InstallDir

if ($Mode -eq 'resolve') {
    exit 0
}

$Slangc = Join-Path $InstallDir 'bin/slangc.exe'
$VersionFile = Join-Path $InstallDir '.slang-version'
if ((Test-Path -Path $Slangc) -and (Test-Path -Path $VersionFile)) {
    $installed = Get-Content -Path $VersionFile -Raw
    $installed = $installed.Trim()
    if ($installed -eq $ResolvedVersion) {
        Write-Host "Slang $ResolvedVersion already installed"
        Add-To-GitHubPath (Join-Path $InstallDir 'bin')
        & $Slangc -v
        exit 0
    }
    Write-Host "Cached Slang version '$installed' does not match '$ResolvedVersion'; replacing cache"
    Remove-Item -Path $InstallDir -Recurse -Force
}

$archive = Join-Path ([IO.Path]::GetTempPath()) (Split-Path -Leaf ([Uri]$DownloadUrl).AbsolutePath)
Invoke-WebRequest -Uri $DownloadUrl -OutFile $archive
try {
    Expand-SlangArchive $archive $InstallDir
} finally {
    if (Test-Path -Path $archive) {
        Remove-Item -Path $archive -Force
    }
}

Set-Content -Path $VersionFile -Value $ResolvedVersion
Add-To-GitHubPath (Join-Path $InstallDir 'bin')
& (Join-Path $InstallDir 'bin/slangc.exe') -v
