<#
.SYNOPSIS
    Installs or uninstalls SakuFix04 from a release ZIP.

.DESCRIPTION
    Installs the runtime files under Program Files and registers the startup task.
    Must be run from the extracted release ZIP in an elevated PowerShell session.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Install,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$RunNow,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$installPath = Join-Path $env:ProgramFiles 'SakuFix04'
$runtimeFiles = @(
    'Fix-0.4GHz.ps1'
    'Apply-Fix04-AtBoot.ps1'
    'Install-Fix04Startup.ps1'
    'RyzenSMU.bin'
)

function Assert-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session ("Run as administrator").'
    }
}

Assert-Elevated

if ($Uninstall) {
    $startupScript = Join-Path $installPath 'Install-Fix04Startup.ps1'
    if (-not (Test-Path -LiteralPath $startupScript)) {
        $startupScript = Join-Path $PSScriptRoot 'Install-Fix04Startup.ps1'
    }

    if (-not (Test-Path -LiteralPath $startupScript)) {
        throw 'Install-Fix04Startup.ps1 was not found in the installation folder or extracted ZIP; cannot safely remove the startup task.'
    }

    & $startupScript -Uninstall
    if (Test-Path -LiteralPath $installPath) {
        Remove-Item -LiteralPath $installPath -Recurse -Force
    }

    Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'SakuFix04') -Filter 'PawnIoInterop-*.dll' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host 'SakuFix04 uninstalled. The diagnostic log in ProgramData was left in place.'
    exit 0
}

foreach ($file in $runtimeFiles) {
    $sourcePath = Join-Path $PSScriptRoot $file
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw ('Required release file not found: {0}' -f $sourcePath)
    }
}

if (-not (Test-Path -LiteralPath $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
}

foreach ($file in $runtimeFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) `
        -Destination (Join-Path $installPath $file) -Force
}

$startupScript = Join-Path $installPath 'Install-Fix04Startup.ps1'
if ($RunNow) {
    & $startupScript -Install -RunNow
}
else {
    & $startupScript -Install
}

Write-Host ('SakuFix04 installed to {0}.' -f $installPath)
Write-Host 'The workaround will be applied automatically at startup as SYSTEM.'
Write-Host 'Use Install-Fix04Startup.ps1 -Status to check the task and log.'
