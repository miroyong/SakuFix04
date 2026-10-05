<#
.SYNOPSIS
    Startup and resume entry point for the Saku Overclock "Fix 0,4 GHz" workaround.

.DESCRIPTION
    Calls Fix-0.4GHz.ps1 -Action Enable -Force and retries if the driver or SMU is not
    ready. Every attempt is appended to C:\ProgramData\SakuFix04\fix04.log.

    Meant to be run by the scheduled task "SakuFix04-0.4GHz" (at startup, as SYSTEM) -
    see Install-Fix04Startup.ps1.

    Note: it applies the workaround unconditionally. The CPU then stays in the fixed
    AcBtc clock state until Fix-0.4GHz.ps1 -Action Disable is run.

.PARAMETER TimeoutSeconds
    How long to keep waiting for the hardware to become ready (default 300 s).

.PARAMETER RetrySeconds
    Delay between readiness attempts (default 5 s).

.PARAMETER Disable
    Undo the workaround instead of applying it.
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 300,

    [int]$RetrySeconds = 5,

    [switch]$Disable
)

$ErrorActionPreference = 'Stop'

$logDirectory = Join-Path $env:ProgramData 'SakuFix04'
$logPath      = Join-Path $logDirectory 'fix04.log'
$fixScript    = Join-Path $PSScriptRoot 'Fix-0.4GHz.ps1'
$mode         = if ($Disable) { 'Disable' } else { 'Enable' }

if (-not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Write-OutputBlock {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim()) { Write-Log ('    ' + $line.Trim()) }
    }
}

if (-not (Test-Path -LiteralPath $fixScript)) {
    Write-Log ('ERROR: {0} not found' -f $fixScript)
    exit 1
}

Write-Log ('--- {0} requested (user {1}) ---' -f $mode.ToUpperInvariant(), $env:USERNAME)

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$attempt = 0
while ((Get-Date) -lt $deadline) {
    $attempt++
    $output = ''
    try {
        $output = & $fixScript -Action $mode -Force *>&1 | Out-String
    }
    catch {
        $output = $_.Exception.Message
    }

    Write-OutputBlock -Text $output

    if ($output -match '->\s*OK') {
        Write-Log ('SUCCESS: workaround {0}d on attempt {1}' -f $mode.ToLowerInvariant(), $attempt)
        exit 0
    }

    if ($output -match 'This codename is not covered|no 0\.4 GHz workaround|PawnIO is not installed|RyzenSMU PawnIO module not found') {
        Write-Log 'FAILED: a required driver/module is missing or this CPU is not supported; not retrying.'
        exit 1
    }

    Write-Log ('  SMU/driver not ready (attempt {0}); retrying in {1} s.' -f $attempt, $RetrySeconds)
    Start-Sleep -Seconds $RetrySeconds
}

Write-Log ('ERROR: PawnIO/SMU did not become ready within {0} s; last attempt {1}.' -f $TimeoutSeconds, $attempt)
exit 1
