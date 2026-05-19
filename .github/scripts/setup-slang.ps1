#requires -Version 7.0
# Resolve, cache, and install Slang for Windows GitHub Actions runners.

param(
    [switch] $ResolveOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $true
}
if (Test-Path variable:PSNativeCommandArgumentPassing) {
    $PSNativeCommandArgumentPassing = 'Standard'
}

function HomeDir {
    if ($HOME) { return $HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return [Environment]::GetFolderPath('UserProfile')
}

function Lower([string] $Value) {
    return $Value.ToLowerInvariant()
}

function InferPlatform {
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
        default { throw "cannot infer Slang platform for architecture '$arch'; set SLANG_PLATFORM" }
    }

    return "$os-$arch"
}

function VersionFromUrl([string] $Url, [string] $Platform) {
    $leaf = Split-Path -Leaf ([Uri] $Url).AbsolutePath
    $escaped = [Regex]::Escape($Platform)
    if ($leaf -match "^slang-(.+)-$escaped\.(zip|tar\.gz)$") {
        return $Matches[1]
    }
    return $null
}

function GitHubApi([string] $Url) {
    $headers = @{
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GH_TOKEN) {
        $headers['Authorization'] = "Bearer $env:GH_TOKEN"
    }
    return Invoke-RestMethod `
        -Uri $Url `
        -Headers $headers `
        -MaximumRetryCount 3 `
        -RetryIntervalSec 2
}

function ResolveRelease([string] $Requested, [string] $Platform, [string] $AssetPattern) {
    if ($Requested -in @('', 'latest', 'auto')) {
        $release = GitHubApi 'https://api.github.com/repos/shader-slang/slang/releases/latest'
    } else {
        $tag = $Requested.TrimStart('v')
        try {
            $release = GitHubApi "https://api.github.com/repos/shader-slang/slang/releases/tags/v$tag"
        } catch {
            $release = GitHubApi "https://api.github.com/repos/shader-slang/slang/releases/tags/$Requested"
        }
    }

    $version = $release.tag_name.TrimStart('v')
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "could not resolve Slang version from request '$Requested'"
    }

    if ([string]::IsNullOrWhiteSpace($AssetPattern)) {
        $names = @(
            "slang-$version-$Platform.zip",
            "slang-$version-$Platform.tar.gz"
        )
        $asset = $release.assets | Where-Object { $names -contains $_.name } | Select-Object -First 1
    } else {
        $asset = $release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    }

    if ($null -eq $asset -or [string]::IsNullOrWhiteSpace($asset.browser_download_url)) {
        $available = ($release.assets | ForEach-Object { $_.name }) -join ', '
        throw "no Slang release asset for version '$version' and platform '$Platform'. Available: $available"
    }

    return @{
        Version = $version
        Url = $asset.browser_download_url
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
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function DownloadFile([string] $Url, [string] $Output) {
    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Output `
        -MaximumRetryCount 3 `
        -RetryIntervalSec 2
}

function ExpandSlangArchive([string] $Archive, [string] $InstallDir) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "slang-extract-$PID"
    ClearDirectory $tempRoot
    try {
        if ($Archive.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
            Expand-Archive -Path $Archive -DestinationPath $tempRoot -Force
        } elseif ($Archive.EndsWith('.tar.gz', [StringComparison]::OrdinalIgnoreCase)) {
            tar -xzf $Archive -C $tempRoot
        } else {
            throw "unsupported Slang archive format: $Archive"
        }

        $slangc = Get-ChildItem -Path $tempRoot -Filter 'slangc.exe' -Recurse -File | Select-Object -First 1
        if ($null -eq $slangc) {
            throw 'slangc.exe not found after Slang extraction'
        }

        $root = if ($slangc.Directory.Name -eq 'bin') {
            $slangc.Directory.Parent.FullName
        } else {
            $slangc.Directory.FullName
        }

        ClearDirectory $InstallDir
        Copy-Item -Path (Join-Path $root '*') -Destination $InstallDir -Recurse -Force
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
$requested = if ($env:SLANG_VERSION) { $env:SLANG_VERSION } else { '2026.9' }
$platform = if ($env:SLANG_PLATFORM) { $env:SLANG_PLATFORM } else { InferPlatform }
$assetPattern = if ($env:SLANG_ASSET_PATTERN) { $env:SLANG_ASSET_PATTERN } else { '' }

if ($env:SLANG_DOWNLOAD_URL) {
    $resolvedVersion = $requested.TrimStart('v')
    if ($resolvedVersion -in @('', 'auto', 'latest')) {
        $resolvedVersion = VersionFromUrl $env:SLANG_DOWNLOAD_URL $platform
    }
    if ([string]::IsNullOrWhiteSpace($resolvedVersion)) {
        throw "could not infer Slang version from URL '$env:SLANG_DOWNLOAD_URL'"
    }
    $downloadUrl = $env:SLANG_DOWNLOAD_URL
} else {
    $resolved = ResolveRelease $requested $platform $assetPattern
    $resolvedVersion = $resolved.Version
    $downloadUrl = $resolved.Url
}

$installDir = if ($env:SLANG_INSTALL_DIR) {
    $env:SLANG_INSTALL_DIR
} else {
    Join-Path (Join-Path $toolRoot 'slang') "$platform-$resolvedVersion"
}

Write-Host "Slang request: $requested"
Write-Host "Slang resolved: $resolvedVersion ($platform)"
Write-Host "Slang install: $installDir"

AddGitHubOutput 'version' $resolvedVersion
AddGitHubOutput 'platform' $platform
AddGitHubOutput 'url' $downloadUrl
AddGitHubOutput 'install_dir' $installDir

if ($ResolveOnly) {
    exit 0
}

$slangBin = Join-Path $installDir 'bin/slangc.exe'
$versionFile = Join-Path $installDir '.slang-version'
if ((Test-Path -Path $slangBin) -and (Test-Path -Path $versionFile)) {
    $installed = (Get-Content -Path $versionFile -Raw).Trim()
    if ($installed -eq $resolvedVersion) {
        AddGitHubPath (Join-Path $installDir 'bin')
        & $slangBin -v
        exit 0
    }
    Write-Host "Replacing stale Slang install '$installed'"
    Remove-Item -Path $installDir -Recurse -Force
}

$archive = Join-Path ([IO.Path]::GetTempPath()) (Split-Path -Leaf ([Uri] $downloadUrl).AbsolutePath)
DownloadFile $downloadUrl $archive
try {
    ExpandSlangArchive $archive $installDir
} finally {
    if (Test-Path -Path $archive) {
        Remove-Item -Path $archive -Force
    }
}

Set-Content -Path $versionFile -Value $resolvedVersion
AddGitHubPath (Join-Path $installDir 'bin')
& $slangBin -v
