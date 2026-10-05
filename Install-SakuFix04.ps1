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
$serviceName = 'SakuFix04'
$serviceDisplayName = 'SakuFix04 0.4 GHz workaround'
$serviceDescription = 'Applies the Saku Overclock 0,4 GHz workaround (AGESA AcBtc) through PawnIO as soon as Windows resumes, without starting a new process.'
$runtimeFiles = @(
    'Fix-0.4GHz.ps1'
    'Apply-Fix04-AtBoot.ps1'
    'Install-Fix04Startup.ps1'
    'SakuFix04.Service.exe'
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
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force
        }
        & sc.exe delete $serviceName | Out-Null
        Write-Host ('Service "{0}" removed.' -f $serviceName)
    }

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

# The service is the primary path: it is already running when Windows resumes, so it does
# not pay for a process start while the processor is stuck at 0.4 GHz. The scheduled task
# stays as a fallback.
$serviceExe = Join-Path $installPath 'SakuFix04.Service.exe'
$quotedServiceExe = '"{0}"' -f $serviceExe

Write-Host ''
Write-Host 'Verifying the native service binary (--apply):'
& $serviceExe --apply --timeout 60
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'The service binary could not apply the workaround right now; the scheduled task remains as the fallback.'
}

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force
    }
    & sc.exe config $serviceName binPath= $quotedServiceExe start= auto | Out-Null
}
else {
    New-Service -Name $serviceName -BinaryPathName $quotedServiceExe -DisplayName $serviceDisplayName `
        -Description $serviceDescription -StartupType Automatic | Out-Null
}

& sc.exe description $serviceName $serviceDescription | Out-Null
& sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000 | Out-Null
Start-Service -Name $serviceName

Write-Host ''
Write-Host ('SakuFix04 installed to {0}.' -f $installPath)
Write-Host ('Service "{0}" is running and applies the workaround on resume; the scheduled task covers boot and logon.' -f $serviceName)
Write-Host 'Use Install-Fix04Startup.ps1 -Status to check the task and the log.'
