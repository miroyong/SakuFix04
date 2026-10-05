<#
.SYNOPSIS
    Standalone version of the Saku Overclock "Fix 0,4 GHz" workaround.

.DESCRIPTION
    Some AMD Ryzen Mobile CPUs (Raven / Picasso, i.e. Ryzen 2000U / 3000U) boot and then
    sit at 0.4 GHz forever. Saku Overclock works around this by putting the CPU into its
    AGESA "AcBtc" - Boot Time Calibration - state (the fixed RAMStates described in
    AcBtc.h), or by switching the matching SMU feature bit, through the MP1 SMU mailbox.

    This script replicates exactly that code path
        Saku Overclock.Core / CpuService.ApplyPreset() / CpuFrequency04Fix
    without the application UI: it talks to the SMU through the PawnIO driver using the
    RyzenSMU PawnIO module that ships inside the installed ZenStates-Core.dll.

    The codename table below mirrors ZenStates-Core's SMU settings classes (mailbox
    addresses, SMU message ids) and the application's codename -> workaround mapping.

.PARAMETER Action
    Status  Read-only. Shows CPU, codename, mailbox and SMU version (default).
    Enable  Applies the workaround.
    Disable Undoes the workaround. On an affected CPU this puts it back to the 0.4 GHz
            state, because that state is the bug the workaround hides - not damage.
            A reboot also clears the AcBtc state (BIOS defaults are re-applied at boot).

.PARAMETER State
    Argument of the AcBtc start command, 0..4 (only used by the AcBtc platforms).
    0 is what the application uses.

.PARAMETER ModulePath
    Optional path to a PawnIO module: either a RyzenSMU.bin, or a ZenStates-Core.dll to
    extract it from. By default a RyzenSMU.bin next to this script is used, then the
    installed Saku Overclock ZenStates-Core.dll. When extracted from the installed DLL,
    the module is cached next to this script for use after Saku is uninstalled.

.PARAMETER Force
    Skips the confirmation prompt before sending SMU commands.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1
    Shows what would be applied on this CPU (read-only). Use -ExecutionPolicy Bypass because
    the default Windows execution policy forbids running .ps1 files.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1 -Action Enable
    Applies the 0.4 GHz fix.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1 -Action Disable
    Undoes the fix.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Enable', 'Disable')]
    [string]$Action = 'Status',

    [ValidateRange(0, 4)]
    [int]$State = 0,

    [string]$ModulePath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# PawnIO interop - same protocol as ZenStates.Core.PawnIo.PawnIo
# ---------------------------------------------------------------------------
if (-not ('PawnIoDevice' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public sealed class PawnIoDevice : IDisposable
{
    private const uint DEVICE_TYPE           = 41394u << 16;
    private const uint IOCTL_PIO_LOAD_BINARY = 0x821u << 2;
    private const uint IOCTL_PIO_EXECUTE_FN  = 0x841u << 2;
    private const int  FN_NAME_LENGTH        = 32;
    private const uint GENERIC_READ          = 0x80000000u;
    private const uint GENERIC_WRITE         = 0x40000000u;
    private const uint FILE_SHARE_ALL        = 0x00000003u;
    private const uint OPEN_EXISTING         = 3u;

    private IntPtr _handle = IntPtr.Zero;

    /// <summary>SMU response status byte of the last command, 0x01 = OK.</summary>
    public uint LastStatus;

    /// <summary>Reason why SendSmuCommand returned null.</summary>
    public string LastError;

    /// <summary>How many times the response register is polled before giving up.</summary>
    public int TimeoutRetries = 2000;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode, byte[] lpInBuffer,
        uint nInBufferSize, byte[] lpOutBuffer, uint nOutBufferSize, out uint lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    public PawnIoDevice()
    {
        _handle = CreateFile(@"\\?\GLOBALROOT\Device\PawnIO", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_ALL,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);

        if (_handle == IntPtr.Zero || _handle.ToInt64() == -1)
        {
            int err = Marshal.GetLastWin32Error();
            _handle = IntPtr.Zero;
            throw new InvalidOperationException("Cannot open the PawnIO device (Win32 error " + err.ToString() + "). " +
                "Is the PawnIO driver installed, and is this process elevated?");
        }
    }

    public bool IsOpen { get { return _handle != IntPtr.Zero && _handle.ToInt64() != -1; } }

    public void LoadModule(byte[] module)
    {
        if (!IsOpen) throw new InvalidOperationException("PawnIO device is not open.");

        uint read;
        if (!DeviceIoControl(_handle, DEVICE_TYPE | IOCTL_PIO_LOAD_BINARY, module, (uint)module.Length,
                null, 0, out read, IntPtr.Zero))
            throw new InvalidOperationException("PawnIO refused to load the RyzenSMU module (Win32 error " +
                Marshal.GetLastWin32Error().ToString() + ").");
    }

    public long[] Execute(string function, long[] input, int outputCount)
    {
        if (!IsOpen) throw new InvalidOperationException("PawnIO device is not open.");
        if (input == null) input = new long[0];

        byte[] inBuffer = new byte[FN_NAME_LENGTH + input.Length * 8];
        byte[] nameBytes = Encoding.ASCII.GetBytes(function);
        Buffer.BlockCopy(nameBytes, 0, inBuffer, 0, Math.Min(FN_NAME_LENGTH - 1, nameBytes.Length));
        Buffer.BlockCopy(input, 0, inBuffer, FN_NAME_LENGTH, input.Length * 8);

        byte[] outBuffer = new byte[outputCount * 8];
        uint read;
        if (!DeviceIoControl(_handle, DEVICE_TYPE | IOCTL_PIO_EXECUTE_FN, inBuffer, (uint)inBuffer.Length,
                outBuffer, (uint)outBuffer.Length, out read, IntPtr.Zero))
            throw new InvalidOperationException("PawnIO function '" + function + "' failed (Win32 error " +
                Marshal.GetLastWin32Error().ToString() + ").");

        long[] result = new long[read / 8];
        Buffer.BlockCopy(outBuffer, 0, result, 0, (int)read);
        return result;
    }

    public int GetCodeName()
    {
        long[] result = Execute("ioctl_get_code_name", new long[0], 1);
        return result.Length > 0 ? (int)result[0] : -1;
    }

    public uint GetSmuVersion()
    {
        long[] result = Execute("ioctl_get_smu_version", new long[0], 1);
        return result.Length > 0 ? (uint)result[0] : 0u;
    }

    public uint ReadSmuRegister(uint address)
    {
        long[] result = Execute("ioctl_read_smu_register", new long[] { address }, 1);
        return result.Length > 0 ? (uint)result[0] : 0u;
    }

    public void WriteSmuRegister(uint address, uint value)
    {
        Execute("ioctl_write_smu_register", new long[] { address, value }, 0);
    }

    private int WaitResponse(uint rspAddress, int retries)
    {
        for (int i = 0; i < retries; i++)
        {
            if (ReadSmuRegister(rspAddress) != 0) return i;
        }
        return -1;
    }

    /// <summary>
    /// Mirrors ZenStates.Core SMU.SendSmuCommand: wait until the mailbox is idle, clear the
    /// response register, write the six arguments, write the message id, wait for the answer
    /// and read the status back. Returns the six response arguments, or null with LastError set.
    /// </summary>
    public uint[] SendSmuCommand(uint msgAddress, uint rspAddress, uint argAddress, uint message, uint[] args)
    {
        LastError = null;
        LastStatus = 0;

        if (WaitResponse(rspAddress, TimeoutRetries) < 0)
        {
            LastError = "mailbox at 0x" + rspAddress.ToString("X8") + " never became ready (response register stayed 0)";
            return null;
        }

        WriteSmuRegister(rspAddress, 0);

        for (int i = 0; i < 6; i++)
            WriteSmuRegister(argAddress + (uint)(i * 4), (args != null && i < args.Length) ? args[i] : 0u);

        WriteSmuRegister(msgAddress, message);

        if (WaitResponse(rspAddress, TimeoutRetries) < 0)
        {
            LastError = "no answer from the mailbox (SMU did not respond to command 0x" + message.ToString("X2") + ")";
            return null;
        }

        LastStatus = ReadSmuRegister(rspAddress);

        uint[] response = new uint[6];
        for (int i = 0; i < 6; i++)
            response[i] = ReadSmuRegister(argAddress + (uint)(i * 4));
        return response;
    }

    public void Dispose()
    {
        if (IsOpen) CloseHandle(_handle);
        _handle = IntPtr.Zero;
    }
}
'@
}

# ---------------------------------------------------------------------------
# Codename list, in the exact order of the RyzenSMU PawnIO module enum
# (PawnIO.Modules / RyzenSMU.p / "const CodeName:").
# ---------------------------------------------------------------------------
$script:CodeNames = @(
    'Colfax', 'Renoir', 'Picasso', 'Matisse', 'Threadripper', 'CastlePeak', 'RavenRidge',
    'RavenRidge2', 'SummitRidge', 'PinnacleRidge', 'Rembrandt', 'Vermeer', 'VanGogh', 'Cezanne',
    'Milan', 'Dali', 'Raphael', 'GraniteRidge', 'Naples', 'FireFlight', 'Rome', 'Chagall',
    'Lucienne', 'Phoenix', 'Phoenix2', 'Mendocino', 'Genoa', 'StormPeak', 'DragonRange', 'Mero',
    'HawkPoint', 'StrixPoint', 'StrixHalo', 'KrackanPoint', 'KrackanPoint2', 'Turin', 'TurinD',
    'Bergamo', 'ShimadaPeak', 'Carrizo', 'BristolRidge', 'StoneyRidge'
)

# SMU mailbox address sets (ZenStates.Core / Hardware / Smu / Settings).
$script:MbAp0   = @{ Msg = 0x03B10528; Rsp = 0x03B10564; Arg = 0x03B10998 }   # Raven, Picasso, Renoir, Cezanne
$script:MbAp1   = @{ Msg = 0x03B10528; Rsp = 0x03B10578; Arg = 0x03B10998 }   # VanGogh, Rembrandt, Phoenix
$script:MbStrix = @{ Msg = 0x03B10928; Rsp = 0x03B10978; Arg = 0x03B10998 }   # Strix, KrackanPoint
$script:MbZen2  = @{ Msg = 0x3B10530;  Rsp = 0x3B1057C;  Arg = 0x3B109C4  }   # Zen2 / Zen3 / Zen4 / Zen5
$script:MbCa    = @{ Msg = 0x13000000; Rsp = 0x13000010; Arg = 0x13000020 }   # Carrizo family

# Codename -> mailbox, SMU message ids and which workaround the application applies:
#   Fix 'Bit37' / 'Bit36' / 'Bit7' : EnableSmuFeatures / DisableSmuFeatures with that bit
#   Fix 'Btc'                      : AcBtc start, or stop + end calibration (AGESA AcBtc state)
#   Fix 'None'                     : the reference implementation applies nothing
$script:Platforms = @{}
function Add-Platform {
    param(
        [string[]]$Names,
        [hashtable]$Memory,
        [int]$Enable,
        [int]$Disable,
        [int]$BtcStart,
        [int]$BtcStop,
        [int]$BtcEnd,
        [string]$Fix
    )
    foreach ($name in $Names) {
        $script:Platforms[$name] = @{
            Memory   = $Memory
            Enable   = $Enable
            Disable  = $Disable
            BtcStart = $BtcStart
            BtcStop  = $BtcStop
            BtcEnd   = $BtcEnd
            Fix      = $Fix
        }
    }
}

# Zen (ZenSettings): AcBtc 0x23/0x24/0x25, SMU features 0x9/0xA
Add-Platform @('SummitRidge', 'Naples', 'Threadripper') $MbAp0 0x9 0xA 0x23 0x24 0x25 'Btc'
# Zen+ (ZenPSettings): neither AcBtc nor feature commands defined
Add-Platform @('PinnacleRidge', 'Colfax') $MbAp0 0 0 0 0 0 'None'
# Zen / Zen+ APUs (APUSettings0) - the classic 0.4 GHz case, AcBtc 0x2F/0x30/0x31
Add-Platform @('RavenRidge', 'FireFlight', 'Picasso', 'Dali') $MbAp0 0x5 0x6 0x2F 0x30 0x31 'Btc'
Add-Platform @('RavenRidge2') $MbAp0 0 0 0 0 0 'None'
# Zen2 APUs (APUSettings1): features 0x5/0x7
Add-Platform @('Renoir', 'Lucienne', 'Cezanne') $MbAp0 0x5 0x7 0 0 0 'Bit37'
Add-Platform @('VanGogh') $MbAp1 0x5 0x7 0 0 0 'Bit37'
Add-Platform @('Mero') $MbAp1 0x5 0x7 0 0 0 'None'
# Zen3 / Zen4 APUs
Add-Platform @('Rembrandt', 'Mendocino', 'Phoenix', 'Phoenix2', 'HawkPoint') $MbAp1 0x5 0x7 0 0 0 'Bit36'
Add-Platform @('StrixPoint', 'StrixHalo', 'KrackanPoint', 'KrackanPoint2') $MbStrix 0x5 0x7 0 0 0 'Bit36'
# Zen2 / Zen3 desktop and server: no AcBtc messages
Add-Platform @('Matisse', 'Vermeer', 'CastlePeak', 'Rome', 'Chagall', 'Milan') $MbZen2 0x5 0x6 0 0 0 'None'
# Zen4 / Zen5: features 0x3/0x4
Add-Platform @('Raphael', 'Genoa', 'StormPeak', 'DragonRange', 'GraniteRidge', 'Bergamo') $MbZen2 0x3 0x4 0 0 0 'Bit7'
Add-Platform @('Turin', 'TurinD') $MbZen2 0x3 0x4 0 0 0 'None'
Add-Platform @('ShimadaPeak') @{ Msg = 0; Rsp = 0; Arg = 0 } 0 0 0 0 0 'None'
# Carrizo family (BristolRidgeSettings): AcBtc start 0x77
Add-Platform @('Carrizo', 'BristolRidge', 'StoneyRidge') $MbCa 0x5F 0x60 0x77 0 0 'Btc'

$script:StatusText = @{
    0x00 = 'SMU_Busy'
    0x01 = 'OK'
    0xFC = 'CMD_REJECTED_BUSY'
    0xFD = 'CMD_REJECTED_PREREQ'
    0xFE = 'UNKNOWN_CMD'
    0xFF = 'FAILED'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Assert-Elevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated ("Run as administrator"): the SMU is reached through the PawnIO kernel driver.'
    }
}

function Test-PawnIoInstalled {
    if (Test-Path 'C:\Program Files\PawnIO\PawnIO.sys') { return $true }
    return $null -ne (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO' -ErrorAction SilentlyContinue)
}

function Get-RyzenSmuModule {
    param([string]$Path)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Path) { $candidates.Add($Path) }
    if ($PSScriptRoot) { $candidates.Add((Join-Path $PSScriptRoot 'RyzenSMU.bin')) }
    $candidates.Add('C:\Program Files\Saku Labs Inc\Saku Overclock\ZenStates-Core.dll')
    foreach ($root in @('C:\Program Files', 'C:\Program Files (x86)')) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Directory -Filter 'Saku*' -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates.Add((Join-Path $_.FullName 'ZenStates-Core.dll')) }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
        $item = Get-Item -LiteralPath $candidate

        if ($item.Extension -ieq '.bin') {
            return @{ Bytes = [IO.File]::ReadAllBytes($item.FullName); Source = $item.FullName }
        }

        # Pull the module out of the installed ZenStates-Core.dll (embedded resource).
        $bytes = $null
        try {
            $assembly = [Reflection.Assembly]::LoadFrom($item.FullName)
            $stream = $assembly.GetManifestResourceStream('ZenStates.Core.Resources.PawnIo.RyzenSMU.bin')
            if ($null -ne $stream) {
                try {
                    $memory = New-Object IO.MemoryStream
                    $stream.CopyTo($memory)
                    $bytes = $memory.ToArray()
                }
                finally {
                    $stream.Dispose()
                    if ($null -ne $memory) { $memory.Dispose() }
                }
            }
        }
        catch {
            Write-Verbose ('Could not read {0}: {1}' -f $item.FullName, $_.Exception.Message)
        }

        if ($null -ne $bytes) {
            $cachePath = Join-Path $PSScriptRoot 'RyzenSMU.bin'
            [IO.File]::WriteAllBytes($cachePath, $bytes)
            return @{ Bytes = $bytes; Source = ($item.FullName + ' (embedded resource; cached locally)') }
        }
    }

    throw 'RyzenSMU PawnIO module not found. Reinstall Saku Overclock once to extract and cache its module, or pass -ModulePath <RyzenSMU.bin> / -ModulePath <ZenStates-Core.dll>.'
}

function Invoke-SmuCommand {
    param(
        [PawnIoDevice]$Device,
        [int]$Message,
        [uint32[]]$CmdArgs,
        [hashtable]$Memory
    )

    $response = $Device.SendSmuCommand([uint32]$Memory.Msg, [uint32]$Memory.Rsp, [uint32]$Memory.Arg, [uint32]$Message, $CmdArgs)
    $status = [int]$Device.LastStatus

    if ($null -eq $response) {
        throw ('SMU command 0x{0:X2}: {1}' -f $Message, $Device.LastError)
    }

    $name = if ($script:StatusText.ContainsKey($status)) { $script:StatusText[$status] } else { ('0x{0:X2}' -f $status) }
    return @{ Message = $Message; Status = $status; StatusName = $name }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Assert-Elevated

if (-not (Test-PawnIoInstalled)) {
    throw 'PawnIO is not installed. Run Saku Overclock once (it installs PawnIO), then retry.'
}

$module = Get-RyzenSmuModule -Path $ModulePath
Write-Host ('RyzenSMU module : {0} ({1} bytes)' -f $module.Source, $module.Bytes.Length)

$device = New-Object PawnIoDevice
$mutex  = $null
try {
    $mutex = New-Object Threading.Mutex($false, 'Global\Access_PCI')
    if (-not $mutex.WaitOne(5000, $false)) {
        Write-Warning 'Another tool is holding "Global\Access_PCI". Close Saku Overclock / other monitoring tools and retry.'
        $mutex.Dispose()
        $mutex = $null
    }
}
catch {
    Write-Warning ('Could not take the "Global\Access_PCI" mutex: ' + $_.Exception.Message)
    $mutex = $null
}

try {
    $device.LoadModule($module.Bytes)

    $index = $device.GetCodeName()
    if ($index -ge 0 -and $index -lt $script:CodeNames.Count) {
        $codeName = $script:CodeNames[$index]
    }
    else {
        $codeName = "unknown (#$index)"
    }
    $platform = if ($script:Platforms.ContainsKey($codeName)) { $script:Platforms[$codeName] } else { $null }

    Write-Host ''
    Write-Host 'CPU'
    if ($Action -eq 'Status') {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        Write-Host ('  {0}' -f $cpu.Name)
    }
    Write-Host ('  codename      : {0} (module id {1})' -f $codeName, $index)

    if ($null -eq $platform) {
        Write-Host ''
        Write-Host 'This codename is not covered by the reference implementation - nothing to do.' -ForegroundColor Yellow
        return
    }

    $memory = $platform.Memory
    Write-Host ('  SMU version   : 0x{0:X8}' -f $device.GetSmuVersion())
    Write-Host ('  workaround    : {0}' -f $platform.Fix)

    if ($platform.Fix -eq 'None') {
        Write-Host ''
        Write-Host 'The reference implementation defines no 0.4 GHz workaround for this codename.' -ForegroundColor Yellow
        return
    }

    $rspProbe = 0
    if ($memory.Rsp -ne 0) { $rspProbe = $device.ReadSmuRegister([uint32]$memory.Rsp) }
    Write-Host ('  MP1 mailbox   : msg 0x{0:X8}  rsp 0x{1:X8} (reads 0x{2:X8})  arg 0x{3:X8}' -f $memory.Msg, $memory.Rsp, $rspProbe, $memory.Arg)

    if ($Action -eq 'Status') {
        # Effective clock: a CPU stuck at 0.4 GHz reports ~19 % of its nominal clock here.
        $effective = $null
        try {
            $perf = (Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop |
                     Where-Object { $_.Name -eq '_Total' }).PercentProcessorPerformance
            if ($perf) { $effective = ('{0:N0} MHz ({1} % of nominal)' -f ($cpu.MaxClockSpeed * $perf / 100), $perf) }
        }
        catch { }
        if ($effective) { Write-Host ('  current clock : {0}' -f $effective) }

        Write-Host ''
        Write-Host 'Read-only mode: nothing was written to the SMU.' -ForegroundColor Green
        Write-Host 'Re-run with -Action Enable to apply the 0.4 GHz workaround.'
        return
    }

    if (-not $Force) {
        $answer = Read-Host ("Send the SMU commands for the '{0}' workaround now? (y/N)" -f $platform.Fix)
        if ($answer -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }

    Write-Host ''
    if ($platform.Fix -eq 'Btc') {
        if ($Action -eq 'Enable') {
            if ($platform.BtcStart -eq 0) {
                throw 'The reference implementation defines no AcBtc start message for this codename.'
            }
            $result = Invoke-SmuCommand -Device $device -Message $platform.BtcStart -CmdArgs @([uint32]$State, 0, 0, 0, 0, 0) -Memory $memory
            Write-Host ('  AcBtcStartCal (0x{0:X2}, state {1}) -> {2}' -f $result.Message, $State, $result.StatusName)
        }
        else {
            if ($platform.BtcStop -eq 0 -or $platform.BtcEnd -eq 0) {
                throw 'The reference implementation defines no AcBtc stop/end messages for this codename.'
            }
            $result = Invoke-SmuCommand -Device $device -Message $platform.BtcStop -CmdArgs @(0, 0, 0, 0, 0, 0) -Memory $memory
            Write-Host ('  AcBtcStopCal  (0x{0:X2}) -> {1}' -f $result.Message, $result.StatusName)
            $result = Invoke-SmuCommand -Device $device -Message $platform.BtcEnd -CmdArgs @(0, 0, 0, 0, 0, 0) -Memory $memory
            Write-Host ('  AcBtcEndCal   (0x{0:X2}) -> {1}' -f $result.Message, $result.StatusName)
        }
    }
    else {
        $bit     = [int]$platform.Fix.Substring(3)
        $message = if ($Action -eq 'Enable') { $platform.Enable } else { $platform.Disable }
        $cmdArgs = New-Object 'uint32[]' 6
        if ($bit -lt 32) { $cmdArgs[0] = [uint32](1 -shl $bit) } else { $cmdArgs[1] = [uint32](1 -shl ($bit - 32)) }

        $result = Invoke-SmuCommand -Device $device -Message $message -CmdArgs $cmdArgs -Memory $memory
        $verb = if ($Action -eq 'Enable') { 'EnableSmuFeatures ' } else { 'DisableSmuFeatures' }
        Write-Host ('  {0} bit {1} (cmd 0x{2:X2}) -> {3}' -f $verb, $bit, $result.Message, $result.StatusName)
    }

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
}
finally {
    if ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
    $device.Dispose()
}
