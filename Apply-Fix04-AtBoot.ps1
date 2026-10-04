<#
.SYNOPSIS
    Boot entry point that applies the Saku Overclock "Fix 0,4 GHz" workaround.

.DESCRIPTION
    Waits until the PawnIO driver, the RyzenSMU module and the SMU mailbox are usable,
    then calls Fix-0.4GHz.ps1 -Action Enable -Force. Every step is appended to
    C:\ProgramData\SakuFix04\fix04.log.

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

function Get-EffectiveClock {
    try {
        $nominal = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).MaxClockSpeed
        $perf = (Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop |
                 Where-Object { $_.Name -eq '_Total' }).PercentProcessorPerformance
        if ($perf) { return ('{0:N0} MHz ({1} % of nominal)' -f ($nominal * $perf / 100), $perf) }
    }
    catch { }
    return 'unknown'
}

if (-not (Test-Path -LiteralPath $fixScript)) {
    Write-Log ('ERROR: {0} not found' -f $fixScript)
    exit 1
}

Write-Log ('--- {0} requested (user {1}) ---' -f $mode.ToUpperInvariant(), $env:USERNAME)

# Readiness: the Status mode is read-only and performs the same hardware checks
# (PawnIO device, RyzenSMU module, SMU version, mailbox) the real run needs.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$probeOutput = $null
while ((Get-Date) -lt $deadline) {
    try {
        $probeOutput = & $fixScript -Action Status *>&1 | Out-String
        break
    }
    catch {
        Write-Log ('  hardware not ready yet: {0}' -f $_.Exception.Message)
        Start-Sleep -Seconds $RetrySeconds
    }
}

if (-not $probeOutput) {
    Write-Log ('ERROR: PawnIO/SMU did not become ready within {0} s' -f $TimeoutSeconds)
    exit 1
}

Write-Log '  hardware ready'
Write-OutputBlock -Text $probeOutput
Write-Log ('  clock before: {0}' -f (Get-EffectiveClock))

try {
    $output = & $fixScript -Action $mode -Force *>&1 | Out-String
}
catch {
    Write-Log ('ERROR: {0}' -f $_.Exception.Message)
    exit 1
}

Write-OutputBlock -Text $output

if ($output -match '->\s*OK') {
    Start-Sleep -Seconds 2
    Write-Log ('  clock after : {0}' -f (Get-EffectiveClock))
    Write-Log ('SUCCESS: workaround {0}d' -f $mode.ToLowerInvariant())
    exit 0
}

Write-Log ('FAILED: the SMU did not answer OK to the {0} request' -f $mode.ToLowerInvariant())
exit 1
