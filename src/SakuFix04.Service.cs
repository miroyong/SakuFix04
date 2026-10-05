// SakuFix04 - resident service for the Ryzen 0.4 GHz workaround.
//
// The scheduled task has to start a PowerShell process to apply the workaround, and that
// process start alone can take minutes while the processor is already stuck at 0.4 GHz.
// This service is running long before, so it can send the SMU command within milliseconds
// of the resume notification.
//
//   SakuFix04.Service.exe               runs as a service (registered by the installer)
//   SakuFix04.Service.exe --apply       applies the workaround once and exits
//   SakuFix04.Service.exe --status      reports the detected platform, changing nothing
//
// Options:
//   --module <path>    RyzenSMU.bin to load (default: the one next to this executable)
//   --timeout <secs>   how long --apply/--status waits for the hardware (default 60)

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class Program
{
    private const string ServiceName = "SakuFix04";

    // The service starts before the PawnIO driver is necessarily usable, so the first
    // attempt keeps retrying for a while; a resume has to be handled within seconds.
    private const int StartupApplyTimeoutSeconds = 900;
    private const int ResumeApplyTimeoutSeconds = 300;
    private const int RetryDelayMilliseconds = 2000;

    private static readonly ServiceMainDelegate ServiceMainReference = ServiceMain;
    private static readonly ServiceControlHandlerDelegate ControlHandlerReference = OnServiceControl;

    private static string _logPath;
    private static ManualResetEvent _stopEvent;
    private static AutoResetEvent _applyEvent;
    private static IntPtr _statusHandle = IntPtr.Zero;

    private static int Main(string[] args)
    {
        _logPath = Path.Combine(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SakuFix04"),
            "fix04.log");

        Fix04.ModulePath = ResolveModulePath(GetOption(args, "module"));

        string command = args.Length > 0 ? args[0].TrimStart('-', '/').ToLowerInvariant() : string.Empty;
        int timeout = ParseInt(GetOption(args, "timeout"), 60);

        switch (command)
        {
            case "apply":
                return RunOnce(true, timeout);
            case "status":
                return RunOnce(false, timeout);
            case "":
                return RunService();
            default:
                Console.Error.WriteLine("Unknown argument '" + args[0] + "'. Use --apply, --status, or no argument to run as a service.");
                return 2;
        }
    }

    // ---------------------------------------------------------------------
    // Service host
    // ---------------------------------------------------------------------
    private static int RunService()
    {
        _stopEvent = new ManualResetEvent(false);
        _applyEvent = new AutoResetEvent(false);

        SERVICE_TABLE_ENTRY[] table = new SERVICE_TABLE_ENTRY[2];
        table[0].lpServiceName = Marshal.StringToHGlobalUni(ServiceName);
        table[0].lpServiceProc = Marshal.GetFunctionPointerForDelegate(ServiceMainReference);
        table[1].lpServiceName = IntPtr.Zero;
        table[1].lpServiceProc = IntPtr.Zero;

        if (!StartServiceCtrlDispatcher(table))
        {
            Log("StartServiceCtrlDispatcher failed (Win32 error " + Marshal.GetLastWin32Error() +
                "); run this executable through the service manager.");
            return 1;
        }

        return 0;
    }

    private static void ServiceMain(int argc, IntPtr argv)
    {
        _statusHandle = RegisterServiceCtrlHandlerEx(ServiceName, ControlHandlerReference, IntPtr.Zero);
        if (_statusHandle == IntPtr.Zero)
        {
            Log("RegisterServiceCtrlHandlerEx failed (Win32 error " + Marshal.GetLastWin32Error() + ").");
            return;
        }

        Thread worker = new Thread(Worker);
        worker.IsBackground = true;

        ReportStatus(SERVICE_RUNNING, SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_POWEREVENT, 0);
        Log("[service] started");
        worker.Start();

        _stopEvent.WaitOne();
        ReportStatus(SERVICE_STOP_PENDING, 0, 5000);
        _applyEvent.Set();
        worker.Join(10000);
        Log("[service] stopped");
        ReportStatus(SERVICE_STOPPED, 0, 0);
    }

    private static int OnServiceControl(int control, int eventType, IntPtr eventData, IntPtr context)
    {
        switch (control)
        {
            case SERVICE_CONTROL_STOP:
            case SERVICE_CONTROL_SHUTDOWN:
                _stopEvent.Set();
                return NO_ERROR;

            case SERVICE_CONTROL_POWEREVENT:
                if (eventType == PBT_APMRESUMEAUTOMATIC || eventType == PBT_APMRESUMESUSPEND || eventType == PBT_APMRESUMECRITICAL)
                {
                    Log("[service] resume notification 0x" + eventType.ToString("X") + "; applying now");
                    _applyEvent.Set();
                }
                return NO_ERROR;

            case SERVICE_CONTROL_INTERROGATE:
                return NO_ERROR;

            default:
                return ERROR_CALL_NOT_IMPLEMENTED;
        }
    }

    private static void Worker()
    {
        bool pending = true;
        DateTime deadline = DateTime.UtcNow.AddSeconds(StartupApplyTimeoutSeconds);

        while (!_stopEvent.WaitOne(0))
        {
            if (pending)
            {
                ApplyResult result = Fix04.Apply(true, "service");

                if (result == ApplyResult.Success)
                {
                    pending = false;
                }
                else if (result == ApplyResult.Fatal)
                {
                    Log("[service] no workaround can be applied on this machine; waiting for a resume or a stop.");
                    pending = false;
                }
                else if (DateTime.UtcNow >= deadline)
                {
                    Log("[service] giving up after repeated failures; the scheduled task remains as a fallback.");
                    pending = false;
                }
            }

            int signaled = WaitHandle.WaitAny(new WaitHandle[] { _stopEvent, _applyEvent },
                pending ? RetryDelayMilliseconds : Timeout.Infinite);

            if (signaled == 0)
            {
                break;
            }
            if (signaled == 1)
            {
                pending = true;
                deadline = DateTime.UtcNow.AddSeconds(ResumeApplyTimeoutSeconds);
            }
        }
    }

    private static void ReportStatus(uint state, uint accepted, uint waitHint)
    {
        if (_statusHandle == IntPtr.Zero)
        {
            return;
        }

        SERVICE_STATUS status = new SERVICE_STATUS();
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = state;
        status.dwControlsAccepted = accepted;
        status.dwWin32ExitCode = 0;
        status.dwServiceSpecificExitCode = 0;
        status.dwCheckPoint = 0;
        status.dwWaitHint = waitHint;
        SetServiceStatus(_statusHandle, ref status);
    }

    // ---------------------------------------------------------------------
    // Console modes
    // ---------------------------------------------------------------------
    private static int RunOnce(bool apply, int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);

        while (true)
        {
            ApplyResult result = apply ? Fix04.Apply(true, "command line") : Fix04.ReportStatus("command line");
            if (result == ApplyResult.Success)
            {
                return 0;
            }
            if (result == ApplyResult.Fatal || DateTime.UtcNow >= deadline)
            {
                return 1;
            }
            Thread.Sleep(RetryDelayMilliseconds);
        }
    }

    // ---------------------------------------------------------------------
    // Logging
    // ---------------------------------------------------------------------
    internal static void Log(string message)
    {
        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message;

        lock (LogLock)
        {
            try
            {
                string directory = Path.GetDirectoryName(_logPath);
                if (!Directory.Exists(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                using (StreamWriter writer = new StreamWriter(_logPath, true, new UTF8Encoding(false)))
                {
                    writer.WriteLine(line);
                }
            }
            catch (IOException)
            {
                // Another writer (the scheduled task) held the file for a moment.
            }
            catch (UnauthorizedAccessException)
            {
            }

            try
            {
                Console.WriteLine(line);
            }
            catch (IOException)
            {
            }
        }
    }

    private static readonly object LogLock = new object();

    // ---------------------------------------------------------------------
    // Argument helpers
    // ---------------------------------------------------------------------
    private static string GetOption(string[] args, string name)
    {
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (string.Equals(args[i].TrimStart('-', '/'), name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }
        return null;
    }

    private static int ParseInt(string text, int fallback)
    {
        int value;
        return int.TryParse(text, out value) ? value : fallback;
    }

    private static string ResolveModulePath(string explicitPath)
    {
        if (!string.IsNullOrEmpty(explicitPath) && File.Exists(explicitPath))
        {
            return explicitPath;
        }

        string nextToExecutable = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "RyzenSMU.bin");
        return File.Exists(nextToExecutable) ? nextToExecutable : null;
    }

    // ---------------------------------------------------------------------
    // Service control interop
    // ---------------------------------------------------------------------
    private const uint SERVICE_WIN32_OWN_PROCESS = 0x00000010;
    private const uint SERVICE_ACCEPT_STOP = 0x00000001;
    private const uint SERVICE_ACCEPT_SHUTDOWN = 0x00000004;
    private const uint SERVICE_ACCEPT_POWEREVENT = 0x00000040;
    private const int SERVICE_CONTROL_STOP = 0x00000001;
    private const int SERVICE_CONTROL_INTERROGATE = 0x00000004;
    private const int SERVICE_CONTROL_SHUTDOWN = 0x00000005;
    private const int SERVICE_CONTROL_POWEREVENT = 0x0000000D;
    private const uint SERVICE_STOP_PENDING = 0x00000003;
    private const uint SERVICE_RUNNING = 0x00000004;
    private const uint SERVICE_STOPPED = 0x00000001;
    private const int NO_ERROR = 0;
    private const int ERROR_CALL_NOT_IMPLEMENTED = 120;

    private const int PBT_APMRESUMECRITICAL = 0x0006;
    private const int PBT_APMRESUMESUSPEND = 0x0007;
    private const int PBT_APMRESUMEAUTOMATIC = 0x0012;

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_TABLE_ENTRY
    {
        public IntPtr lpServiceName;
        public IntPtr lpServiceProc;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS
    {
        public uint dwServiceType;
        public uint dwCurrentState;
        public uint dwControlsAccepted;
        public uint dwWin32ExitCode;
        public uint dwServiceSpecificExitCode;
        public uint dwCheckPoint;
        public uint dwWaitHint;
    }

    private delegate void ServiceMainDelegate(int argc, IntPtr argv);

    private delegate int ServiceControlHandlerDelegate(int control, int eventType, IntPtr eventData, IntPtr context);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool StartServiceCtrlDispatcher([In] SERVICE_TABLE_ENTRY[] lpServiceStartTable);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr RegisterServiceCtrlHandlerEx(string lpServiceName, ServiceControlHandlerDelegate lpHandlerProc, IntPtr lpContext);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetServiceStatus(IntPtr hServiceStatus, ref SERVICE_STATUS lpServiceStatus);
}

// -------------------------------------------------------------------------
// The workaround itself - a C# port of Fix-0.4GHz.ps1 with the same PawnIO protocol.
// -------------------------------------------------------------------------
internal enum ApplyResult
{
    Success,
    Retry,
    Fatal
}

internal static class Fix04
{
    internal static string ModulePath;

    private static readonly string[] CodeNames = new string[]
    {
        "Colfax", "Renoir", "Picasso", "Matisse", "Threadripper", "CastlePeak", "RavenRidge",
        "RavenRidge2", "SummitRidge", "PinnacleRidge", "Rembrandt", "Vermeer", "VanGogh", "Cezanne",
        "Milan", "Dali", "Raphael", "GraniteRidge", "Naples", "FireFlight", "Rome", "Chagall",
        "Lucienne", "Phoenix", "Phoenix2", "Mendocino", "Genoa", "StormPeak", "DragonRange", "Mero",
        "HawkPoint", "StrixPoint", "StrixHalo", "KrackanPoint", "KrackanPoint2", "Turin", "TurinD",
        "Bergamo", "ShimadaPeak", "Carrizo", "BristolRidge", "StoneyRidge"
    };

    private static readonly Dictionary<uint, string> StatusText = new Dictionary<uint, string>
    {
        { 0x00, "SMU_Busy" },
        { 0x01, "OK" },
        { 0xFC, "CMD_REJECTED_BUSY" },
        { 0xFD, "CMD_REJECTED_PREREQ" },
        { 0xFE, "UNKNOWN_CMD" },
        { 0xFF, "FAILED" }
    };

    private static readonly Dictionary<string, Platform> Platforms = BuildPlatforms();

    internal static ApplyResult Apply(bool enable, string origin)
    {
        return Run(origin, delegate(PawnIoDevice device, Platform platform)
        {
            if (!enable)
            {
                return Disable(device, platform, origin);
            }
            return Enable(device, platform, origin);
        });
    }

    internal static ApplyResult ReportStatus(string origin)
    {
        return Run(origin, delegate(PawnIoDevice device, Platform platform)
        {
            uint response = platform.Memory.Rsp != 0 ? device.ReadSmuRegister(platform.Memory.Rsp) : 0;
            Program.Log("[" + origin + "] MP1 mailbox msg 0x" + platform.Memory.Msg.ToString("X8") +
                "  rsp 0x" + platform.Memory.Rsp.ToString("X8") + " (reads 0x" + response.ToString("X8") +
                ")  arg 0x" + platform.Memory.Arg.ToString("X8"));
            Program.Log("[" + origin + "] read-only: nothing was written to the SMU.");
            return ApplyResult.Success;
        });
    }

    private delegate ApplyResult PlatformAction(PawnIoDevice device, Platform platform);

    private static ApplyResult Run(string origin, PlatformAction action)
    {
        if (string.IsNullOrEmpty(ModulePath))
        {
            Program.Log("[" + origin + "] RyzenSMU.bin was not found next to the executable; pass --module <path>.");
            return ApplyResult.Fatal;
        }

        try
        {
            byte[] module = File.ReadAllBytes(ModulePath);
            using (PawnIoDevice device = new PawnIoDevice())
            {
                device.LoadModule(module);

                int index = device.GetCodeName();
                string codeName = (index >= 0 && index < CodeNames.Length) ? CodeNames[index] : "unknown (#" + index + ")";

                Platform platform;
                if (!Platforms.TryGetValue(codeName, out platform))
                {
                    Program.Log("[" + origin + "] codename " + codeName + " (module id " + index + ") is not covered by the reference implementation.");
                    return ApplyResult.Fatal;
                }

                Program.Log("[" + origin + "] " + codeName + " (module id " + index + "), SMU 0x" +
                    device.GetSmuVersion().ToString("X8") + ", workaround " + platform.Fix + ", module " + ModulePath);

                if (platform.Fix == "None")
                {
                    Program.Log("[" + origin + "] the reference implementation defines no workaround for this codename.");
                    return ApplyResult.Fatal;
                }

                return action(device, platform);
            }
        }
        catch (Exception exception)
        {
            Program.Log("[" + origin + "] " + exception.Message);
            return ApplyResult.Retry;
        }
    }

    private static ApplyResult Enable(PawnIoDevice device, Platform platform, string origin)
    {
        if (platform.Fix == "Btc")
        {
            if (platform.BtcStart == 0)
            {
                Program.Log("[" + origin + "] no AcBtc start message is defined for this codename.");
                return ApplyResult.Fatal;
            }
            uint status = Send(device, platform, platform.BtcStart, new uint[6],
                "AcBtcStartCal (0x" + platform.BtcStart.ToString("X2") + ", state 0)");
            return status == 0x01 ? ApplyResult.Success : ApplyResult.Retry;
        }

        return SetFeature(device, platform, true);
    }

    private static ApplyResult Disable(PawnIoDevice device, Platform platform, string origin)
    {
        if (platform.Fix == "Btc")
        {
            if (platform.BtcStop == 0 || platform.BtcEnd == 0)
            {
                Program.Log("[" + origin + "] no AcBtc stop/end messages are defined for this codename.");
                return ApplyResult.Fatal;
            }
            uint status = Send(device, platform, platform.BtcStop, new uint[6],
                "AcBtcStopCal  (0x" + platform.BtcStop.ToString("X2") + ")");
            if (status != 0x01)
            {
                return ApplyResult.Retry;
            }
            status = Send(device, platform, platform.BtcEnd, new uint[6],
                "AcBtcEndCal   (0x" + platform.BtcEnd.ToString("X2") + ")");
            return status == 0x01 ? ApplyResult.Success : ApplyResult.Retry;
        }

        return SetFeature(device, platform, false);
    }

    private static ApplyResult SetFeature(PawnIoDevice device, Platform platform, bool enable)
    {
        int bit = int.Parse(platform.Fix.Substring(3));
        uint[] arguments = new uint[6];
        if (bit < 32)
        {
            arguments[0] = 1u << bit;
        }
        else
        {
            arguments[1] = 1u << (bit - 32);
        }

        uint message = enable ? platform.Enable : platform.Disable;
        if (message == 0)
        {
            Program.Log("[interop] no SMU feature command is defined for this codename.");
            return ApplyResult.Fatal;
        }

        string verb = enable ? "EnableSmuFeatures " : "DisableSmuFeatures";
        uint status = Send(device, platform, message, arguments,
            verb + " bit " + bit + " (cmd 0x" + message.ToString("X2") + ")");
        return status == 0x01 ? ApplyResult.Success : ApplyResult.Retry;
    }

    private static uint Send(PawnIoDevice device, Platform platform, uint message, uint[] arguments, string description)
    {
        uint[] response = device.SendSmuCommand(platform.Memory.Msg, platform.Memory.Rsp, platform.Memory.Arg, message, arguments);
        if (response == null)
        {
            Program.Log("  " + description + ": " + device.LastError);
            return 0;
        }

        uint status = device.LastStatus;
        string name;
        if (!StatusText.TryGetValue(status, out name))
        {
            name = "0x" + status.ToString("X2");
        }
        Program.Log("  " + description + " -> " + name);
        return status;
    }

    // ---------------------------------------------------------------------
    // Platform table (mirrors ZenStates-Core's SMU settings classes)
    // ---------------------------------------------------------------------
    private struct Mailbox
    {
        public uint Msg;
        public uint Rsp;
        public uint Arg;

        public Mailbox(uint msg, uint rsp, uint arg)
        {
            Msg = msg;
            Rsp = rsp;
            Arg = arg;
        }
    }

    private sealed class Platform
    {
        public Mailbox Memory;
        public uint Enable;
        public uint Disable;
        public uint BtcStart;
        public uint BtcStop;
        public uint BtcEnd;
        public string Fix;
    }

    private static Dictionary<string, Platform> BuildPlatforms()
    {
        // SMU mailbox address sets (ZenStates.Core / Hardware / Smu / Settings).
        Mailbox ap0 = new Mailbox(0x03B10528, 0x03B10564, 0x03B10998);   // Raven, Picasso, Renoir, Cezanne
        Mailbox ap1 = new Mailbox(0x03B10528, 0x03B10578, 0x03B10998);   // VanGogh, Rembrandt, Phoenix
        Mailbox strix = new Mailbox(0x03B10928, 0x03B10978, 0x03B10998); // Strix, KrackanPoint
        Mailbox zen2 = new Mailbox(0x3B10530, 0x3B1057C, 0x3B109C4);     // Zen2 / Zen3 / Zen4 / Zen5
        Mailbox carrizo = new Mailbox(0x13000000, 0x13000010, 0x13000020); // Carrizo family

        Dictionary<string, Platform> platforms = new Dictionary<string, Platform>(StringComparer.Ordinal);
        Add(platforms, new string[] { "SummitRidge", "Naples", "Threadripper" }, ap0, 0x9, 0xA, 0x23, 0x24, 0x25, "Btc");
        Add(platforms, new string[] { "PinnacleRidge", "Colfax" }, ap0, 0, 0, 0, 0, 0, "None");
        Add(platforms, new string[] { "RavenRidge", "FireFlight", "Picasso", "Dali" }, ap0, 0x5, 0x6, 0x2F, 0x30, 0x31, "Btc");
        Add(platforms, new string[] { "RavenRidge2" }, ap0, 0, 0, 0, 0, 0, "None");
        Add(platforms, new string[] { "Renoir", "Lucienne", "Cezanne" }, ap0, 0x5, 0x7, 0, 0, 0, "Bit37");
        Add(platforms, new string[] { "VanGogh" }, ap1, 0x5, 0x7, 0, 0, 0, "Bit37");
        Add(platforms, new string[] { "Mero" }, ap1, 0x5, 0x7, 0, 0, 0, "None");
        Add(platforms, new string[] { "Rembrandt", "Mendocino", "Phoenix", "Phoenix2", "HawkPoint" }, ap1, 0x5, 0x7, 0, 0, 0, "Bit36");
        Add(platforms, new string[] { "StrixPoint", "StrixHalo", "KrackanPoint", "KrackanPoint2" }, strix, 0x5, 0x7, 0, 0, 0, "Bit36");
        Add(platforms, new string[] { "Matisse", "Vermeer", "CastlePeak", "Rome", "Chagall", "Milan" }, zen2, 0x5, 0x6, 0, 0, 0, "None");
        Add(platforms, new string[] { "Raphael", "Genoa", "StormPeak", "DragonRange", "GraniteRidge", "Bergamo" }, zen2, 0x3, 0x4, 0, 0, 0, "Bit7");
        Add(platforms, new string[] { "Turin", "TurinD" }, zen2, 0x3, 0x4, 0, 0, 0, "None");
        Add(platforms, new string[] { "ShimadaPeak" }, new Mailbox(0, 0, 0), 0, 0, 0, 0, 0, "None");
        Add(platforms, new string[] { "Carrizo", "BristolRidge", "StoneyRidge" }, carrizo, 0x5F, 0x60, 0x77, 0, 0, "Btc");
        return platforms;
    }

    private static void Add(Dictionary<string, Platform> platforms, string[] names, Mailbox memory,
        uint enable, uint disable, uint btcStart, uint btcStop, uint btcEnd, string fix)
    {
        foreach (string name in names)
        {
            Platform platform = new Platform();
            platform.Memory = memory;
            platform.Enable = enable;
            platform.Disable = disable;
            platform.BtcStart = btcStart;
            platform.BtcStop = btcStop;
            platform.BtcEnd = btcEnd;
            platform.Fix = fix;
            platforms[name] = platform;
        }
    }
}

// -------------------------------------------------------------------------
// PawnIO interop - same protocol as ZenStates.Core.PawnIo.PawnIo
// -------------------------------------------------------------------------
internal sealed class PawnIoDevice : IDisposable
{
    private const uint DeviceType = 41394u << 16;
    private const uint IoctlPioLoadBinary = 0x821u << 2;
    private const uint IoctlPioExecuteFn = 0x841u << 2;
    private const int FunctionNameLength = 32;
    private const uint GenericRead = 0x80000000u;
    private const uint GenericWrite = 0x40000000u;
    private const uint FileShareAll = 0x00000003u;
    private const uint OpenExisting = 3u;

    private IntPtr _handle = IntPtr.Zero;

    public uint LastStatus;
    public string LastError;
    public int TimeoutRetries = 2000;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFile(string fileName, uint desiredAccess, uint shareMode,
        IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(IntPtr device, uint controlCode, byte[] inBuffer,
        uint inBufferSize, byte[] outBuffer, uint outBufferSize, out uint bytesReturned, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public PawnIoDevice()
    {
        _handle = CreateFile(@"\\?\GLOBALROOT\Device\PawnIO", GenericRead | GenericWrite, FileShareAll,
            IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);

        if (_handle == IntPtr.Zero || _handle.ToInt64() == -1)
        {
            int error = Marshal.GetLastWin32Error();
            _handle = IntPtr.Zero;
            throw new InvalidOperationException("Cannot open the PawnIO device (Win32 error " + error + "). " +
                "Is the PawnIO driver installed, and is this process elevated?");
        }
    }

    public bool IsOpen
    {
        get { return _handle != IntPtr.Zero && _handle.ToInt64() != -1; }
    }

    public void LoadModule(byte[] module)
    {
        if (!IsOpen)
        {
            throw new InvalidOperationException("PawnIO device is not open.");
        }

        uint written;
        if (!DeviceIoControl(_handle, DeviceType | IoctlPioLoadBinary, module, (uint)module.Length,
                null, 0, out written, IntPtr.Zero))
        {
            throw new InvalidOperationException("PawnIO refused to load the RyzenSMU module (Win32 error " +
                Marshal.GetLastWin32Error() + ").");
        }
    }

    public long[] Execute(string function, long[] input, int outputCount)
    {
        if (!IsOpen)
        {
            throw new InvalidOperationException("PawnIO device is not open.");
        }
        if (input == null)
        {
            input = new long[0];
        }

        byte[] inBuffer = new byte[FunctionNameLength + input.Length * 8];
        byte[] nameBytes = Encoding.ASCII.GetBytes(function);
        Buffer.BlockCopy(nameBytes, 0, inBuffer, 0, Math.Min(FunctionNameLength - 1, nameBytes.Length));
        Buffer.BlockCopy(input, 0, inBuffer, FunctionNameLength, input.Length * 8);

        byte[] outBuffer = new byte[outputCount * 8];
        uint read;
        if (!DeviceIoControl(_handle, DeviceType | IoctlPioExecuteFn, inBuffer, (uint)inBuffer.Length,
                outBuffer, (uint)outBuffer.Length, out read, IntPtr.Zero))
        {
            throw new InvalidOperationException("PawnIO function '" + function + "' failed (Win32 error " +
                Marshal.GetLastWin32Error() + ").");
        }

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

    private int WaitResponse(uint responseAddress, int retries)
    {
        for (int i = 0; i < retries; i++)
        {
            if (ReadSmuRegister(responseAddress) != 0)
            {
                return i;
            }
        }
        return -1;
    }

    /// <summary>
    /// Mirrors ZenStates.Core SMU.SendSmuCommand: wait until the mailbox is idle, clear the
    /// response register, write the six arguments, write the message id, wait for the answer
    /// and read the status back.
    /// </summary>
    public uint[] SendSmuCommand(uint msgAddress, uint responseAddress, uint argAddress, uint message, uint[] args)
    {
        LastError = null;
        LastStatus = 0;

        if (WaitResponse(responseAddress, TimeoutRetries) < 0)
        {
            LastError = "mailbox at 0x" + responseAddress.ToString("X8") + " never became ready (response register stayed 0)";
            return null;
        }

        WriteSmuRegister(responseAddress, 0);

        for (int i = 0; i < 6; i++)
        {
            WriteSmuRegister(argAddress + (uint)(i * 4), (args != null && i < args.Length) ? args[i] : 0u);
        }

        WriteSmuRegister(msgAddress, message);

        if (WaitResponse(responseAddress, TimeoutRetries) < 0)
        {
            LastError = "no answer from the mailbox (SMU did not respond to command 0x" + message.ToString("X2") + ")";
            return null;
        }

        LastStatus = ReadSmuRegister(responseAddress);

        uint[] response = new uint[6];
        for (int i = 0; i < 6; i++)
        {
            response[i] = ReadSmuRegister(argAddress + (uint)(i * 4));
        }
        return response;
    }

    public void Dispose()
    {
        if (IsOpen)
        {
            CloseHandle(_handle);
        }
        _handle = IntPtr.Zero;
    }
}
