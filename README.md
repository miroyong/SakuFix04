# SakuFix04

PowerShell scripts to diagnose and apply the Ryzen mobile CPU workaround for systems
that get stuck near 0.4 GHz after boot. The workaround communicates with the AMD SMU
through the PawnIO driver; the Saku Overclock application itself is not required.

> **Warning:** `Enable` sends commands to the SMU and changes the processor's clock
> state. Use only on compatible hardware and at your own risk. `Disable` undoes the
> workaround and may cause an affected processor to become stuck at 0.4 GHz again.

## Requirements

- Windows with PowerShell.
- The PawnIO driver installed.
- Administrator privileges to access the driver and manage the scheduled task.
- The `RyzenSMU.bin` module included in this repository.

The script detects the processor codename and only applies settings defined in its
platform table. The reference implementation does not define a workaround for every
codename.

## Manual use

Open PowerShell as an administrator in the project directory.

Check the CPU, codename, SMU version, and mailbox without sending any modifying
commands:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1 -Action Status
```

Apply the workaround:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1 -Action Enable
```

The script asks for confirmation before sending the command. To explicitly undo the
workaround:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1 -Action Disable
```

The `-ModulePath` parameter accepts an alternative `RyzenSMU.bin` or
`ZenStates-Core.dll`. Without this parameter, the script first looks for
`RyzenSMU.bin` next to the script, then tries to find the module in the Saku Overclock
installation.

## Apply automatically at startup

### Install from a GitHub Release

Download and extract `SakuFix04-<version>.zip` from
[GitHub Releases](https://github.com/miroyong/SakuFix04/releases). Open PowerShell as
an administrator in the extracted folder, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SakuFix04.ps1 -Install
```

The installer copies the required files to `C:\Program Files\SakuFix04` and registers
the `SakuFix04-0.4GHz` scheduled task to run at startup as `SYSTEM`. Add `-RunNow` to
also start the task immediately. The installer does not execute the workaround directly;
it registers the startup task.

Check the task status and latest log lines:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\SakuFix04\Install-Fix04Startup.ps1" -Status
```

To uninstall, run the installer from the extracted ZIP in an elevated PowerShell
session:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SakuFix04.ps1 -Uninstall
```

Uninstallation removes the scheduled task and installed program files. The diagnostic
log at `C:\ProgramData\SakuFix04\fix04.log` is retained.

Pushing a version tag such as `v1.0.0` automatically creates a GitHub Release and
attaches the ZIP package.

### Manual setup from a source checkout

Alternatively, register the scheduled task from an elevated PowerShell prompt:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Install
```

The `SakuFix04-0.4GHz` task runs `Apply-Fix04-AtBoot.ps1` at startup as `SYSTEM` with
elevated privileges, again when a user signs in, and again when Windows resumes from
sleep or hibernation. It applies the workaround as soon as the SMU is ready and retries
only if an attempt fails. The startup run happens before user sign-in; the logon run is
a backstop in case the hardware was not ready yet.

The compiled PawnIO interop assembly is cached under `C:\ProgramData\SakuFix04` and
reused by later runs. Compiling it takes a few seconds on an idle CPU but about a minute
while the processor is stuck at 0.4 GHz, so the cache removes that cost from every boot
and resume.

Check the task status and view the latest log lines:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Status
```

The log is written to `C:\ProgramData\SakuFix04\fix04.log`. To also run the task
immediately after registering it, add `-RunNow` to the installation command.

If the `SYSTEM` account cannot open the PawnIO device, register a task that runs when
the current user logs on instead:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Install -AsUser
```

Remove the scheduled task:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Uninstall
```

## Module source

`RyzenSMU.bin` is the PawnIO module from the
[ZenStates-Core](https://github.com/irusanov/ZenStates-Core) project, distributed here
under the GPL-3.0 license included in [`LICENSE`](./LICENSE). The file matches the
upstream repository at commit
[`bcd76fa`](https://github.com/irusanov/ZenStates-Core/tree/bcd76fa6f03ea4fde8dd5f3e0e8b98944567a076).
