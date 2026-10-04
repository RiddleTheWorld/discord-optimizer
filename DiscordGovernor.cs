// DiscordGovernor: throttles Discord while it is in the background and not using audio.
// Background + silent  -> EcoQoS (efficiency mode), below-normal CPU priority, low memory priority.
// Focused or audio     -> Windows defaults.
// Optional: restart Discord (to the tray) when it has bloated past a memory limit and you've been away.
//
// Usage: DiscordGovernor.exe [--restart-above-mb N] [--clear-cache-above-mb N] [--maintain] [--idle-minutes M] [--interval-ms X] [--once] [--log]
//        DiscordGovernor.exe --report     show each Discord process's current state
//        DiscordGovernor.exe --restore    undo throttling now
// Written for the C# 5 compiler that ships with Windows (built by Optimize-Discord.ps1).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

static class Native
{
    [StructLayout(LayoutKind.Sequential)] public struct POWER_THROTTLING { public uint Version, ControlMask, StateMask; }
    [StructLayout(LayoutKind.Sequential)] public struct MEMORY_PRIORITY { public uint Priority; }
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize, dwTime; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    public delegate void WinEventProc(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    public const int ProcessMemoryPriority = 0, ProcessPowerThrottling = 4;
    public const uint ExecutionSpeed = 1, EventSystemForeground = 3, WmTimer = 0x0113;

    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetProcessInformation(IntPtr h, int cls, ref POWER_THROTTLING info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetProcessInformation(IntPtr h, int cls, ref MEMORY_PRIORITY info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetProcessInformation(IntPtr h, int cls, ref POWER_THROTTLING info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetProcessInformation(IntPtr h, int cls, ref MEMORY_PRIORITY info, int size);
    [DllImport("kernel32.dll")] public static extern bool AttachConsole(int pid);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SetTimer(IntPtr hwnd, IntPtr id, uint ms, IntPtr proc);
    [DllImport("user32.dll")] public static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);
}

// Minimal Core Audio interop: is any Discord process playing or recording right now?
static class Audio
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        int GetAudioSessionControl(IntPtr groupingParam, int flags, out IntPtr sessionControl);
        int GetSimpleAudioVolume(IntPtr groupingParam, int flags, out IntPtr audioVolume);
        int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        int GetCount(out int count);
        int GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        int GetState(out int state);
        int GetDisplayName(out IntPtr name);
        int SetDisplayName(IntPtr name, IntPtr ctx);
        int GetIconPath(out IntPtr path);
        int SetIconPath(IntPtr path, IntPtr ctx);
        int GetGroupingParam(out Guid param);
        int SetGroupingParam(IntPtr param, IntPtr ctx);
        int RegisterAudioSessionNotification(IntPtr client);
        int UnregisterAudioSessionNotification(IntPtr client);
        int GetSessionIdentifier(out IntPtr id);
        int GetSessionInstanceIdentifier(out IntPtr id);
        int GetProcessId(out uint pid);
    }

    const int AllFlows = 2, DeviceStateActive = 1, ClsctxAll = 23, SessionActive = 1;
    public const int Render = 1, Capture = 2;

    // Activating a session manager per device is the expensive part, so keep them and refresh
    // every few minutes (or right away if one fails, e.g. a headset was unplugged).
    static List<KeyValuePair<IAudioSessionManager2, bool>> managers;   // manager, isCapture
    static IMMDeviceEnumerator enumerator;
    static int managersForCount = -1;   // how many devices were active when the managers were built

    // Cheap (no device activation), so it can run on every check to notice a headset being plugged in
    static int ActiveDeviceCount()
    {
        if (enumerator == null) enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDeviceCollection devices;
        int count;
        if (enumerator.EnumAudioEndpoints(AllFlows, DeviceStateActive, out devices) != 0) return -1;
        devices.GetCount(out count);
        return count;
    }
    static DateTime managersAt;

    static void RefreshManagers()
    {
        managers = new List<KeyValuePair<IAudioSessionManager2, bool>>();
        managersAt = DateTime.UtcNow;
        if (enumerator == null) enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDeviceCollection devices;
        if (enumerator.EnumAudioEndpoints(AllFlows, DeviceStateActive, out devices) != 0) return;
        int count;
        devices.GetCount(out count);
        var iid = typeof(IAudioSessionManager2).GUID;
        for (int i = 0; i < count; i++)
        {
            IMMDevice device;
            object o;
            if (devices.Item(i, out device) != 0 || device.Activate(ref iid, ClsctxAll, IntPtr.Zero, out o) != 0) continue;
            managers.Add(new KeyValuePair<IAudioSessionManager2, bool>((IAudioSessionManager2)o, IsCaptureDevice(device)));
        }
    }

    // Returns a bitmask of Render/Capture for active sessions owned by the given processes.
    public static int ActiveFlows(HashSet<uint> pids)
    {
        // Rebuild when a device was plugged in or removed, and every 5 minutes for swaps that keep the count the same
        int deviceCount = ActiveDeviceCount();
        if (managers == null || deviceCount != managersForCount || (DateTime.UtcNow - managersAt).TotalMinutes > 5)
        {
            RefreshManagers();
            managersForCount = deviceCount;
        }
        int result = 0;
        foreach (var m in managers)
        {
            IAudioSessionEnumerator sessions;
            if (m.Key.GetSessionEnumerator(out sessions) != 0) { managers = null; continue; }
            int n;
            sessions.GetCount(out n);
            for (int j = 0; j < n; j++)
            {
                object s;
                if (sessions.GetSession(j, out s) != 0) continue;
                var control = (IAudioSessionControl2)s;
                int state; uint pid;
                if (control.GetState(out state) == 0 && state == SessionActive &&
                    control.GetProcessId(out pid) == 0 && pids.Contains(pid))
                    result |= m.Value ? Capture : Render;
            }
        }
        return result;
    }

    [ComImport, Guid("1BE09788-6894-4089-8586-9A2A6C265AC5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMEndpoint { int GetDataFlow(out int flow); }

    static bool IsCaptureDevice(IMMDevice device)
    {
        int flow;
        return ((IMMEndpoint)device).GetDataFlow(out flow) == 0 && flow == 1;
    }
}

class Governor
{
    static string[] Names = { "Discord", "DiscordPTB", "DiscordCanary" };   // --names overrides (for testing)
    static readonly string LogPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"DiscordOptimizer\governor.log");

    // Filled in by Optimize-Discord.ps1 when it builds the helper, from the lists in DiscordCommon.ps1:
    // CachePaths = $DiscordAreaPaths of the areas marked Cache (folders and files under %APPDATA%\discord),
    // OptionalModules = $DiscordOptionalModules. Compiled on its own, both stay empty and the helper only throttles.
    static readonly string[] CachePaths = { /*@CachePaths@*/ };
    static readonly string[] OptionalModules = { /*@OptionalModules@*/ };

    static readonly string[] RoamingNames = { "discord", "discordptb", "discordcanary" };    // under %APPDATA%
    static readonly string[] InstallFolders = { "Discord", "DiscordPTB", "DiscordCanary" };   // under %LOCALAPPDATA%

    readonly Dictionary<int, bool> applied = new Dictionary<int, bool>();   // pid -> throttled?
    readonly Dictionary<int, ProcessPriorityClass> original = new Dictionary<int, ProcessPriorityClass>();   // Chromium runs the GPU process above normal
    readonly int restartAboveMB, idleMinutes, clearCacheAboveMB;
    readonly bool log, maintain;
    DateTime lastRestart = DateTime.MinValue, lastCacheCheck = DateTime.MinValue, lastMaintain = DateTime.MinValue;
    Native.WinEventProc hookProc;   // kept alive so the GC can't collect the callback

    Governor(int restartAboveMB, int idleMinutes, int clearCacheAboveMB, bool maintain, bool log)
    {
        this.restartAboveMB = restartAboveMB;
        this.idleMinutes = idleMinutes;
        this.clearCacheAboveMB = clearCacheAboveMB;
        this.maintain = maintain;
        this.log = log;
    }

    // Discord updates bring back optional modules, every language pack and the previous version.
    // While Discord is closed (at most every 30 minutes), remove them again. Deleted, not backed up:
    // the first removal kept the backup, and Discord re-downloads a module whenever a feature needs it.
    void MaybeMaintain()
    {
        if (!maintain || (DateTime.Now - lastMaintain).TotalMinutes < 30) return;
        lastMaintain = DateTime.Now;
        string local = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var ui = CultureInfo.CurrentUICulture;
        var keepLocales = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "en-US", ui.Name, ui.TwoLetterISOLanguageName };
        foreach (var flavor in InstallFolders)
        {
            string root = Path.Combine(local, flavor);
            if (!Directory.Exists(root)) continue;
            var apps = new DirectoryInfo(root).GetDirectories("app-*")
                .Select(d => new { Dir = d, Version = ParseVersion(d.Name.Substring(4)) })
                .Where(a => a.Version != null).OrderBy(a => a.Version).Select(a => a.Dir).ToList();
            if (apps.Count == 0) continue;
            var current = apps[apps.Count - 1];
            // A version folder created moments ago may still be getting its files from Discord's updater
            if ((DateTime.Now - current.CreationTime).TotalMinutes < 2) { lastMaintain = DateTime.MinValue; continue; }
            int removed = 0;
            foreach (var old in apps.Take(apps.Count - 1)) removed += Remove(old.FullName);

            string modules = Path.Combine(current.FullName, "modules");
            if (Directory.Exists(modules))
                foreach (var d in new DirectoryInfo(modules).GetDirectories())
                    if (OptionalModules.Contains(Regex.Replace(d.Name, @"-\d+$", ""))) removed += Remove(d.FullName);

            string locales = Path.Combine(current.FullName, "locales");
            if (Directory.Exists(locales))
                foreach (var f in new DirectoryInfo(locales).GetFiles("*.pak"))
                    if (!keepLocales.Contains(Path.GetFileNameWithoutExtension(f.Name))) removed += Remove(f.FullName);

            if (removed > 0) Log("kept " + flavor + " clean: removed " + removed + " item(s) that came back");
        }
    }

    static Version ParseVersion(string s)
    {
        Version v;
        return Version.TryParse(s, out v) ? v : null;
    }

    int Remove(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
            else Directory.Delete(path, true);
            return 1;
        }
        catch (Exception e) { Log("remove " + path + " failed: " + e.Message); return 0; }
    }

    // Only while Discord is closed (its cache files are locked while it runs), at most every 30 minutes.
    // In practice: at sign-in before you open Discord, and shortly after you quit it.
    void MaybeClearCache()
    {
        if (clearCacheAboveMB <= 0 || (DateTime.Now - lastCacheCheck).TotalMinutes < 30) return;
        lastCacheCheck = DateTime.Now;
        string appData = Environment.GetEnvironmentVariable("APPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        // Totalled across Discord, PTB and Canary, the same way the window's cache bar adds them up
        var paths = RoamingNames.SelectMany(f => CachePaths.Select(p => Path.Combine(appData, f, p)))
                                .Where(p => Directory.Exists(p) || File.Exists(p)).ToList();
        long mb = paths.Sum(p => PathBytes(p)) >> 20;
        if (mb < clearCacheAboveMB) return;
        foreach (var p in paths) Remove(p);
        Log("cleared " + mb + " MB of cache (limit " + clearCacheAboveMB + " MB)");
    }

    static long PathBytes(string path)
    {
        try
        {
            if (File.Exists(path)) return new FileInfo(path).Length;
            long total = 0;
            foreach (var f in new DirectoryInfo(path).EnumerateFiles("*", SearchOption.AllDirectories)) total += f.Length;
            return total;
        }
        catch { return 0; }
    }

    void Log(string msg)
    {
        if (!log) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
            if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 1 << 20) File.Delete(LogPath);
            File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + msg + Environment.NewLine);
        }
        catch { }
    }

    static bool DiscordUpdaterRunning()
    {
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        foreach (var p in Process.GetProcessesByName("Update"))
        {
            using (p)
            {
                try
                {
                    string path = p.MainModule.FileName;
                    if (InstallFolders.Any(f => path.StartsWith(Path.Combine(local, f) + "\\", StringComparison.OrdinalIgnoreCase))) return true;
                }
                catch { }   // another app's Update.exe we can't inspect
            }
        }
        return false;
    }

    // One process snapshot instead of one per name
    static List<Process> DiscordProcesses()
    {
        var list = new List<Process>();
        foreach (var p in Process.GetProcesses())
        {
            if (Names.Contains(p.ProcessName)) list.Add(p);
            else p.Dispose();
        }
        return list;
    }

    void Evaluate()
    {
        var procs = DiscordProcesses();
        try
        {
            if (procs.Count == 0)
            {
                applied.Clear();
                // Launching starts Discord's Update.exe a moment before Discord.exe; don't delete anything under it
                if (!DiscordUpdaterRunning()) { MaybeClearCache(); MaybeMaintain(); }
                return;
            }
            var pids = new HashSet<uint>(procs.Select(p => (uint)p.Id));

            uint fg;
            Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out fg);
            int audio = 0;
            bool focused = pids.Contains(fg);
            if (!focused)
            {
                try { audio = Audio.ActiveFlows(pids); } catch (Exception e) { Log("audio check failed: " + e.Message); }
            }
            bool throttle = !focused && audio == 0;
            if (applied.Count == 0 || applied.Values.Any(v => v != throttle))
                Log((throttle ? "throttle" : "restore") + ": foreground pid " + fg + (pids.Contains(fg) ? " (Discord)" : "") + ", audio " + audio);

            foreach (var p in procs)
            {
                // Discord closing: its processes can exit between the snapshot and here
                try { if (p.HasExited) continue; } catch { continue; }
                bool current;
                if (applied.TryGetValue(p.Id, out current) && current == throttle) continue;
                try { Apply(p, throttle); }
                catch (Exception e) { Log("apply " + p.Id + " failed: " + e.Message); }   // e.g. Discord running as administrator
                applied[p.Id] = throttle;   // either way, don't retry (and re-log) until the state changes
            }
            foreach (var dead in applied.Keys.Where(k => !pids.Contains((uint)k)).ToList()) { applied.Remove(dead); original.Remove(dead); }

            MaybeRestart(procs, throttle);
        }
        finally { foreach (var p in procs) p.Dispose(); }
    }

    void Apply(Process p, bool throttle)
    {
        var power = new Native.POWER_THROTTLING { Version = 1, ControlMask = throttle ? Native.ExecutionSpeed : 0, StateMask = throttle ? Native.ExecutionSpeed : 0 };
        Native.SetProcessInformation(p.Handle, Native.ProcessPowerThrottling, ref power, Marshal.SizeOf(power));
        var memory = new Native.MEMORY_PRIORITY { Priority = throttle ? 2u : 5u };   // 2 = low, 5 = normal
        Native.SetProcessInformation(p.Handle, Native.ProcessMemoryPriority, ref memory, Marshal.SizeOf(memory));
        // Discord never runs below normal on its own; if it is, a previous helper was killed mid-throttle
        if (!original.ContainsKey(p.Id))
            original[p.Id] = p.PriorityClass == ProcessPriorityClass.BelowNormal ? ProcessPriorityClass.Normal : p.PriorityClass;
        p.PriorityClass = throttle ? ProcessPriorityClass.BelowNormal : original[p.Id];
        Log((throttle ? "throttled " : "restored  ") + p.ProcessName + " " + p.Id);
    }

    void MaybeRestart(List<Process> procs, bool idleAndSilent)
    {
        if (restartAboveMB <= 0 || !idleAndSilent || (DateTime.Now - lastRestart).TotalHours < 6) return;
        var info = new Native.LASTINPUTINFO { cbSize = 8 };
        if (!Native.GetLastInputInfo(ref info) || unchecked((uint)Environment.TickCount - info.dwTime) < idleMinutes * 60000u) return;

        var stable = procs.Where(p => p.ProcessName == "Discord").ToList();
        long mb = stable.Sum(p => { try { return p.PrivateMemorySize64; } catch { return 0L; } }) >> 20;
        if (mb < restartAboveMB) return;

        Log("restarting Discord at " + mb + " MB");
        lastRestart = DateTime.Now;
        foreach (var p in stable) { try { p.Kill(); } catch { } }
        Thread.Sleep(3000);
        string update = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Discord\Update.exe");
        if (File.Exists(update)) Process.Start(update, "--processStart Discord.exe --process-start-args \"--start-minimized\"");
    }

    // Undo throttling without restarting Discord (original priorities aren't known here, so BelowNormal -> Normal)
    static void RestoreAll()
    {
        foreach (var p in DiscordProcesses())
        {
            using (p)
            {
                try
                {
                    var power = new Native.POWER_THROTTLING { Version = 1 };
                    Native.SetProcessInformation(p.Handle, Native.ProcessPowerThrottling, ref power, Marshal.SizeOf(power));
                    var memory = new Native.MEMORY_PRIORITY { Priority = 5 };
                    Native.SetProcessInformation(p.Handle, Native.ProcessMemoryPriority, ref memory, Marshal.SizeOf(memory));
                    if (p.PriorityClass == ProcessPriorityClass.BelowNormal) p.PriorityClass = ProcessPriorityClass.Normal;
                }
                catch { }
            }
        }
    }

    static void Report()
    {
        var all = DiscordProcesses();
        int audio = 0;
        try { audio = Audio.ActiveFlows(new HashSet<uint>(all.Select(p => (uint)p.Id))); } catch { }
        Console.WriteLine("audio: render={0} capture={1}", (audio & Audio.Render) != 0, (audio & Audio.Capture) != 0);
        foreach (var p in all)
        {
            using (p)
            {
                var power = new Native.POWER_THROTTLING { Version = 1 };
                var memory = new Native.MEMORY_PRIORITY();
                bool okP = Native.GetProcessInformation(p.Handle, Native.ProcessPowerThrottling, ref power, Marshal.SizeOf(power));
                bool okM = Native.GetProcessInformation(p.Handle, Native.ProcessMemoryPriority, ref memory, Marshal.SizeOf(memory));
                Console.WriteLine("{0,-8} {1,-14} priority={2,-12} ecoqos={3,-5} memprio={4}", p.Id, p.ProcessName, p.PriorityClass,
                    okP ? ((power.StateMask & 1) != 0).ToString() : "?", okM ? memory.Priority.ToString() : "?");
            }
        }
    }

    [STAThread]
    static int Main(string[] args)
    {
        int restartAbove = 0, idleMinutes = 30, intervalMs = 10000;   // focus changes are event-driven; polling only catches audio
        int clearCacheAbove = 0;
        bool once = false, log = false, report = false, restore = false, maintain = false;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--restart-above-mb": restartAbove = int.Parse(args[++i]); break;
                case "--clear-cache-above-mb": clearCacheAbove = int.Parse(args[++i]); break;
                case "--idle-minutes": idleMinutes = int.Parse(args[++i]); break;
                case "--interval-ms": intervalMs = int.Parse(args[++i]); break;
                case "--names": Names = args[++i].Split(','); break;
                case "--maintain": maintain = true; break;
                case "--once": once = true; break;
                case "--log": log = true; break;
                case "--report": report = true; break;
                case "--restore": restore = true; break;
            }
        }
        if (report) { Native.AttachConsole(-1); Report(); return 0; }
        if (restore) { RestoreAll(); return 0; }

        var g = new Governor(restartAbove, idleMinutes, clearCacheAbove, maintain, log);
        g.Log("started (restart-above-mb=" + restartAbove + ", clear-cache-above-mb=" + clearCacheAbove + ", idle-minutes=" + idleMinutes +
              (maintain ? ", maintain" : "") + (once ? ", once" : "") + ")");
        // A one-off pass is safe next to a running instance; the long-running one must be unique
        if (once) { g.Evaluate(); return 0; }

        bool created;
        using (var mutex = new Mutex(true, @"Local\DiscordGovernor", out created))
        {
            if (!created) return 1;
            g.Evaluate();

            // React instantly to focus changes; poll for audio, new processes and memory.
            g.hookProc = (h, e, hwnd, o, c, t, time) => g.Evaluate();
            Native.SetWinEventHook(Native.EventSystemForeground, Native.EventSystemForeground, IntPtr.Zero, g.hookProc, 0, 0, 0);
            Native.SetTimer(IntPtr.Zero, IntPtr.Zero, (uint)intervalMs, IntPtr.Zero);
            Native.MSG msg;
            while (Native.GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
            {
                if (msg.message == Native.WmTimer && msg.hwnd == IntPtr.Zero) g.Evaluate();
                else Native.DispatchMessage(ref msg);
            }
        }
        return 0;
    }
}
