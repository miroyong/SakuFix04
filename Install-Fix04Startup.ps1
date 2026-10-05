<#
.SYNOPSIS
    Registers the scheduled task that applies the Saku Overclock 0,4 GHz fix at startup,
    at logon and after resuming from sleep or hibernation.

.DESCRIPTION
    Creates the task "SakuFix04-0.4GHz" which runs Apply-Fix04-AtBoot.ps1 as SYSTEM with
    the highest privileges and writes to C:\ProgramData\SakuFix04\fix04.log.

    Must run elevated. Use -AsUser if SYSTEM turns out not to be allowed to open the
    PawnIO device on this machine: that switches the task to "at logon" for the current
    user, still with the highest privileges.

.PARAMETER Install
    Register (or update) the task. This is the default when no switch is given.

.PARAMETER Uninstall
    Remove the task.

.PARAMETER Status
    Show the task state, last result and the tail of the log.

.PARAMETER TaskName
    Name of the scheduled task (default "SakuFix04-0.4GHz").

.PARAMETER RunNow
    Start the task immediately after registering it.

.PARAMETER AsUser
    Register an "at logon" task for the current user instead of "at startup" as SYSTEM.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1
    Registers the startup task.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Status
    Shows the task state and the log.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Uninstall
    Removes the task.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Install,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$RunNow,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$AsUser,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [string]$TaskName = 'SakuFix04-0.4GHz'
)

$ErrorActionPreference = 'Stop'

$wrapper = Join-Path $PSScriptRoot 'Apply-Fix04-AtBoot.ps1'
$logPath = Join-Path (Join-Path $env:ProgramData 'SakuFix04') 'fix04.log'

if ($Uninstall) { $action = 'Uninstall' }
elseif ($Status) { $action = 'Status' }
else { $action = 'Install' }

function Assert-Elevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated ("Run as administrator") to manage the scheduled task.'
    }
}

switch ($action) {
    'Install' {
        Assert-Elevated

        if (-not (Test-Path -LiteralPath $wrapper)) {
            throw ('{0} not found.' -f $wrapper)
        }

        $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $wrapper)

        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -MultipleInstances IgnoreNew

        if ($AsUser) {
            $userId    = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
            $triggers  = @(New-ScheduledTaskTrigger -AtLogOn -User $userId)
            $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
            $when      = 'at logon, highest privileges'
        }
        else {
            # The logon trigger is a backstop: if the startup run was too early or the
            # hardware was not ready, the fix is applied while the user signs in.
            $triggers  = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn))
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $when      = 'at startup and at logon, as SYSTEM'
        }

        Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $triggers `
            -Principal $principal -Settings $settings -Force `
            -Description 'Applies the Saku Overclock 0,4 GHz workaround (AGESA AcBtc) through PawnIO.' | Out-Null

        $taskXml = [xml](Export-ScheduledTask -TaskName $TaskName)
        $namespace = $taskXml.DocumentElement.NamespaceURI
        $triggers = $taskXml.Task.Triggers
        foreach ($existingTrigger in @($taskXml.SelectNodes("//*[local-name()='EventTrigger']"))) {
            [void]$existingTrigger.ParentNode.RemoveChild($existingTrigger)
        }

        # Event 107 is written as soon as the system resumes from sleep, event 1 when it
        # returns from any low power state (including hibernation).
        $subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[(Provider[@Name=''Microsoft-Windows-Kernel-Power''] and EventID=107) or (Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1)]]</Select></Query></QueryList>'
        $resumeTrigger = $taskXml.CreateElement('EventTrigger', $namespace)
        $enabledElement = $taskXml.CreateElement('Enabled', $namespace)
        $enabledElement.InnerText = 'true'
        [void]$resumeTrigger.AppendChild($enabledElement)
        $subscriptionElement = $taskXml.CreateElement('Subscription', $namespace)
        $subscriptionElement.InnerText = $subscription
        [void]$resumeTrigger.AppendChild($subscriptionElement)
        $delayElement = $taskXml.CreateElement('Delay', $namespace)
        $delayElement.InnerText = 'PT10S'
        [void]$resumeTrigger.AppendChild($delayElement)
        [void]$triggers.AppendChild($resumeTrigger)

        Register-ScheduledTask -TaskName $TaskName -Xml $taskXml.OuterXml -Force | Out-Null

        Write-Host ('Task "{0}" registered ({1}; again at logon and after resume from sleep/hibernation).' -f $TaskName, $when)
        Write-Host ('Log: {0}' -f $logPath)

        if ($RunNow) {
            Start-ScheduledTask -TaskName $TaskName
            Write-Host 'Task started now (check -Action Status in a few seconds).'
        }
    }

    'Uninstall' {
        Assert-Elevated

        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host ('Task "{0}" removed.' -f $TaskName)
        }
        else {
            Write-Host ('Task "{0}" was not registered.' -f $TaskName)
        }
    }

    'Status' {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

        if (-not $task) {
            Write-Host ('Task "{0}" is not registered.' -f $TaskName)
        }
        else {
            Write-Host ('Task       : {0}' -f $task.TaskName)
            Write-Host ('State      : {0}' -f $task.State)
            Write-Host ('Trigger    : {0}' -f ($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }))
            Write-Host ('Run as     : {0}' -f $task.Principal.UserId)
            try {
                $info = Get-ScheduledTaskInfo -TaskName $TaskName
                Write-Host ('Last run   : {0}' -f $info.LastRunTime)
                Write-Host ('Last result: {0}' -f $info.LastTaskResult)
                Write-Host ('Next run   : {0}' -f $info.NextRunTime)
            }
            catch {
                Write-Host ('Last run   : (needs elevation to read)')
            }
        }

        if (Test-Path -LiteralPath $logPath) {
            Write-Host ''
            Write-Host ('--- last 12 log lines ({0}) ---' -f $logPath)
            Get-Content -LiteralPath $logPath -Tail 12
        }
        else {
            Write-Host ''
            Write-Host ('No log yet ({0}).' -f $logPath)
        }
    }
}
