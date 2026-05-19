#requires -Version 7.0
# Enable long paths for the current Windows CI runner job.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $true
}
if (Test-Path variable:PSNativeCommandArgumentPassing) {
    $PSNativeCommandArgumentPassing = 'Standard'
}

$registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
New-ItemProperty `
    -Path $registryPath `
    -Name 'LongPathsEnabled' `
    -Value 1 `
    -PropertyType DWORD `
    -Force | Out-Null

git config --global core.longpaths true

Write-Host 'Enabled Windows long paths for this runner job.'
