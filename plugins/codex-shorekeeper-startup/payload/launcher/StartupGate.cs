// Window readiness gate. Original implementation; informed by the alpha gate in
// yanami-sec/codex-startup-animation-windows. Only the process created here is gated.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Net;
using System.Xml;

internal sealed class StartupGate : ApplicationContext {
    private delegate void EventProc(IntPtr hook, uint ev, IntPtr window, int obj, int child, uint thread, uint time);
    private delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, EventProc callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll", EntryPoint="GetCurrentThreadId")] private static extern uint CurrentThread();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr window);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent,EnumProc callback,IntPtr data);
    [DllImport("user32.dll")] private static extern IntPtr SetFocus(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeout(IntPtr window,uint message,IntPtr wParam,IntPtr lParam,uint flags,uint timeout,out IntPtr result);
    [DllImport("iphlpapi.dll")] private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, uint reserved);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr window, int index, int value);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr window, uint color, byte alpha, uint flags);
    [DllImport("user32.dll")] private static extern bool GetLayeredWindowAttributes(IntPtr window, out uint color, out byte alpha, out uint flags);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    private const int ExStyle = -20, Layered = 0x80000, ToolWindow = 0x80;
    private sealed class SavedWindow {
        public IntPtr Handle;
        public int Style;
        public uint Color, Flags;
        public byte Alpha;
        public string Serialize() { return Handle.ToInt64()+"|"+Style+"|"+Color+"|"+Alpha+"|"+Flags; }
        public static SavedWindow Parse(string line) {
            string[] s = line.Split('|');
            return new SavedWindow { Handle = new IntPtr(long.Parse(s[0])), Style = int.Parse(s[1]), Color = uint.Parse(s[2]), Alpha = byte.Parse(s[3]), Flags = uint.Parse(s[4]) };
        }
    }
    private readonly string exe, signal;
    private readonly Dictionary<IntPtr, SavedWindow> windows = new Dictionary<IntPtr, SavedWindow>();
    private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 16 };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly Stopwatch fade = new Stopwatch();
    private readonly EventProc callback;
    private IntPtr hook;
    private Process app;
    private int appPid;
    private long appStarted;
    private bool revealing, finished;

    private StartupGate(string executable, string arguments, string state) {
        exe = Path.GetFullPath(executable);
        signal = Path.GetFullPath(state);
        Directory.CreateDirectory(Path.GetDirectoryName(signal));
        callback = OnWindow;
        // Hook before process creation. Callbacks are delivered on this message
        // loop only after appPid is assigned, and always check that exact PID.
        hook = SetWinEventHook(0x8000, 0x800B, IntPtr.Zero, callback, 0, 0, 2);
        if (hook == IntPtr.Zero) throw new InvalidOperationException("Window event hook unavailable");
        AppDomain.CurrentDomain.ProcessExit += (s,e) => RestoreAll();
        AppDomain.CurrentDomain.UnhandledException += (s,e) => RestoreAll();
        try {
            app = Process.Start(new ProcessStartInfo(exe, arguments) { UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden });
            appPid = app.Id;
            appStarted = app.StartTime.ToUniversalTime().Ticks;
            File.WriteAllText(signal + ".pid", appPid.ToString(CultureInfo.InvariantCulture));
            File.WriteAllText(signal + ".identity", appPid+"|"+appStarted+"|"+exe);
            // This independent process rescues opacity if this gate crashes or
            // its UI loop hangs. It can only restore windows of this exact app.
            Process.Start(new ProcessStartInfo(Application.ExecutablePath,
                "--watchdog " + Quote(signal) + " " + appPid + " " + appStarted + " " + Process.GetCurrentProcess().Id + " " + Quote(exe)) {
                    UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden
                });
            timer.Tick += Tick;
            timer.Start();
            Journal("launched");
        } catch {
            RestoreAll();
            // If state-file/watchdog creation failed before any HWND was saved,
            // wait briefly for this new process's main window and show it. A
            // baseline process can never enter this path or match this identity.
            var rescueClock = Stopwatch.StartNew();
            while (appPid != 0 && SameApp(appPid, appStarted, exe) && rescueClock.Elapsed.TotalSeconds < 10) {
                if (ShowUnrecordedMainWindows(appPid, appStarted, exe)) break;
                Thread.Sleep(50);
            }
            if (hook != IntPtr.Zero) UnhookWinEvent(hook);
            throw;
        }
    }
    private static string Quote(string value) {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
    private void Journal(string action) {
        try { File.AppendAllText(signal + ".timing", clock.ElapsedMilliseconds + " " + action + Environment.NewLine); } catch {}
    }
    private bool OwnWindow(IntPtr window) {
        uint pid;
        GetWindowThreadProcessId(window, out pid);
        return IsWindow(window) && pid == (uint)appPid;
    }
    private void OnWindow(IntPtr h, uint ev, IntPtr window, int obj, int child, uint thread, uint time) {
        if (obj == 0 && child == 0) Hide(window);
    }
    private void Hide(IntPtr window) {
        if (finished || revealing || appPid == 0 || File.Exists(signal + ".abort") || !OwnWindow(window)) return;
        var name = new StringBuilder(128);
        GetClassName(window, name, name.Capacity);
        if (name.ToString() != "Chrome_WidgetWin_1") return;
        Rect bounds;
        if (!GetWindowRect(window, out bounds) || (!IsIconic(window) && (bounds.Right - bounds.Left < 640 || bounds.Bottom - bounds.Top < 400))) return;
        int style = GetWindowLong(window, ExStyle);
        if ((style & ToolWindow) != 0) return;
        SavedWindow saved;
        if (!windows.TryGetValue(window, out saved)) {
            uint color = 0, flags = 2;
            byte alpha = 255;
            if ((style & Layered) != 0 && !GetLayeredWindowAttributes(window, out color, out alpha, out flags)) { color = 0; alpha = 255; flags = 2; }
            saved = new SavedWindow { Handle = window, Style = style, Color = color, Alpha = alpha, Flags = flags };
            // Persist original attributes before the first opacity mutation.
            File.AppendAllText(signal + ".windows", saved.Serialize() + Environment.NewLine);
            windows.Add(window, saved);
            Journal("main-window-gated initiallyVisible=" + IsWindowVisible(window));
        }
        SetWindowLong(window, ExStyle, GetWindowLong(window, ExStyle) | Layered);
        SetLayeredWindowAttributes(window, 0, 0, 2);
        // Alpha zero preserves compositor activity. A minimized/hidden HWND
        // would stall Chromium's first video frame and create a reveal hitch.
        ShowWindow(window, IsIconic(window) ? 9 : 8); // Restore minimized while alpha remains zero.
    }
    private void Tick(object sender, EventArgs args) {
        try {
            if (finished) return;
            if (File.Exists(signal + ".abort") || clock.Elapsed.TotalSeconds >= 20 || app.HasExited) { ReleaseImmediately("fail-open"); return; }
            if (revealing) {
                double t = Math.Min(1, fade.Elapsed.TotalMilliseconds / 140.0);
                byte alpha = (byte)Math.Round(255 * (1 - Math.Pow(1-t, 3)));
                foreach (var w in windows.Values) if (OwnWindow(w.Handle)) SetLayeredWindowAttributes(w.Handle, 0, alpha, 2);
                if (t >= 1) {
                    RestoreAll();
                    if (ForegroundOwnedMain(appPid, appStarted, exe, 2500) != IntPtr.Zero) {
                        File.WriteAllText(signal + ".shown", "foreground-confirmed");
                        Journal("foreground-confirmed"); Finish("ready");
                    } else ReleaseImmediately("foreground-not-confirmed");
                }
                return;
            }
            EnumWindows((window,data) => { Hide(window); return true; }, IntPtr.Zero);
            if (File.Exists(signal + ".ready") && windows.Count > 0) {
                revealing = true;
                fade.Start();
                foreach (var w in windows.Values) if (OwnWindow(w.Handle)) { ShowWindow(w.Handle, 5); SetForegroundWindow(w.Handle); }
                Journal("native-reveal-start");
            }
        } catch { ReleaseImmediately("gate-error"); }
    }
    private void RestoreAll() {
        foreach (var w in windows.Values) if (OwnWindow(w.Handle)) Restore(w);
    }
    private static void Restore(SavedWindow w) {
        if (!IsWindow(w.Handle)) return;
        SetLayeredWindowAttributes(w.Handle, w.Color, w.Alpha, w.Flags == 0 ? 2 : w.Flags);
        // The application may add frame/taskbar flags during initialization.
        // Restore only our transparency bit, preserving those legitimate edits.
        int current = GetWindowLong(w.Handle, ExStyle);
        SetWindowLong(w.Handle, ExStyle, (current & ~Layered) | (w.Style & Layered));
        ShowWindow(w.Handle, 5); // SW_SHOW: preserve the client's window layout.
    }
    private void ReleaseImmediately(string reason) {
        try { File.WriteAllText(signal + ".abort", reason); } catch {}
        RestoreAll();
        try { File.WriteAllText(signal + ".shown", reason); } catch {}
        Finish(reason);
    }
    private void Finish(string reason) {
        if (finished) return;
        finished = true;
        timer.Stop();
        if (hook != IntPtr.Zero) { UnhookWinEvent(hook); hook = IntPtr.Zero; }
        Journal("gate-finished-" + reason);
        try { File.WriteAllText(signal + ".done", reason); } catch {}
        ExitThread();
    }
    private static bool SameApp(int pid, long started, string exe) {
        try { using (var p = Process.GetProcessById(pid)) return !p.HasExited && p.StartTime.ToUniversalTime().Ticks == started && String.Equals(p.MainModule.FileName, exe, StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }
    private static bool ShowUnrecordedMainWindows(int appPid, long started, string exe) {
        if (!SameApp(appPid, started, exe)) return false;
        bool found = false;
        EnumWindows((window,data) => {
            uint pid;
            GetWindowThreadProcessId(window, out pid);
            if (pid != (uint)appPid) return true;
            var name = new StringBuilder(128);
            GetClassName(window, name, name.Capacity);
            Rect bounds;
            if (name.ToString() == "Chrome_WidgetWin_1" && GetWindowRect(window, out bounds) && (IsIconic(window) || (bounds.Right-bounds.Left >= 640 && bounds.Bottom-bounds.Top >= 400)) && (GetWindowLong(window, ExStyle) & ToolWindow) == 0) {
                ShowWindow(window, IsIconic(window) ? 9 : 5);
                found = true;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    private static IntPtr MainWindow(int pid) {
        IntPtr selected = IntPtr.Zero;
        long best=long.MinValue;
        EnumWindows((window,data) => {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)pid) return true;
            var name = new StringBuilder(128); GetClassName(window, name, 128);
            Rect r;
            if (name.ToString() == "Chrome_WidgetWin_1" && (GetWindowLong(window, ExStyle) & ToolWindow) == 0 && GetWindowRect(window, out r) && (IsIconic(window) || (r.Right-r.Left >= 640 && r.Bottom-r.Top >= 400))) {
                long area=Math.Max(0,(long)(r.Right-r.Left)*(r.Bottom-r.Top));
                // Hidden Chromium bootstrap HWNDs can coexist with the real
                // titled app window. Never show a blank helper instead of the
                // minimized main window merely because it comes first in Z order.
                long score=(IsIconic(window)?4000000L:0)+(GetWindowTextLength(window)>0?2000000L:0)+(IsWindowVisible(window)?1000000L:0)+Math.Min(area,900000L)+(GetForegroundWindow()==window?10000L:0);
                if(score>best){best=score;selected=window;}
            }
            return true;
        }, IntPtr.Zero);
        return selected;
    }
    private static IntPtr ForegroundOwnedMain(int pid, long started, string exe, int timeout) {
        var watch=Stopwatch.StartNew();
        do {
            if (!SameApp(pid,started,exe)) return IntPtr.Zero;
            IntPtr w=MainWindow(pid);
            if(w!=IntPtr.Zero) {
                if(IsIconic(w)){IntPtr ignoredMessage;SendMessageTimeout(w,0x0112,new IntPtr(0xF120),IntPtr.Zero,2,500,out ignoredMessage);}
                ShowWindow(w,IsIconic(w)?9:5);
                uint ignored; uint foregroundThread=GetWindowThreadProcessId(GetForegroundWindow(),out ignored), current=CurrentThread();
                bool attached=foregroundThread!=0 && foregroundThread!=current && AttachThreadInput(current,foregroundThread,true);
                uint targetThread=GetWindowThreadProcessId(w,out ignored);
                bool targetAttached=targetThread!=0&&targetThread!=current&&targetThread!=foregroundThread&&AttachThreadInput(current,targetThread,true);
                try {
                    BringWindowToTop(w); SetForegroundWindow(w);
                    IntPtr content=IntPtr.Zero;long largest=0;
                    EnumChildWindows(w,(child,data)=>{
                        var type=new StringBuilder(128);GetClassName(child,type,128);Rect r;
                        if(type.ToString()=="Chrome_RenderWidgetHostHWND"&&IsWindowVisible(child)&&GetWindowRect(child,out r)){
                            long area=(long)(r.Right-r.Left)*(r.Bottom-r.Top);if(area>largest){largest=area;content=child;}
                        }
                        return true;
                    },IntPtr.Zero);
                    SetFocus(content!=IntPtr.Zero?content:w);
                }
                finally { if(targetAttached)AttachThreadInput(current,targetThread,false);if(attached) AttachThreadInput(current,foregroundThread,false); }
                if(IsWindowVisible(w)&&!IsIconic(w)&&GetForegroundWindow()==w) return w;
            }
            Thread.Sleep(35);
        } while(watch.ElapsedMilliseconds<timeout);
        return IntPtr.Zero;
    }
    private static void JsonResult(string file, string code, bool ok, int pid, IntPtr hwnd) {
        uint color,flags;byte alpha=255;if(hwnd!=IntPtr.Zero&&!GetLayeredWindowAttributes(hwnd,out color,out alpha,out flags))alpha=255;
        uint foregroundPid;GetWindowThreadProcessId(GetForegroundWindow(),out foregroundPid);
        File.WriteAllText(file,"{\"ok\":"+(ok?"true":"false")+",\"code\":\""+code+"\",\"pid\":"+pid+",\"foregroundPid\":"+foregroundPid+",\"hwnd\":\""+hwnd.ToInt64()+"\",\"alpha\":"+alpha+",\"foreground\":"+(hwnd!=IntPtr.Zero&&GetForegroundWindow()==hwnd?"true":"false")+",\"visible\":"+(hwnd!=IntPtr.Zero&&IsWindowVisible(hwnd)?"true":"false")+",\"iconic\":"+(hwnd!=IntPtr.Zero&&IsIconic(hwnd)?"true":"false")+"}");
    }
    private static bool OfficialExe(string exe) {
        try {
            exe=Path.GetFullPath(exe);
            string prefix=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"WindowsApps")+Path.DirectorySeparatorChar;
            if(!exe.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)||!String.Equals(Path.GetFileName(exe),"ChatGPT.exe",StringComparison.OrdinalIgnoreCase))return false;
            string root=Directory.GetParent(Path.GetDirectoryName(exe)).FullName;
            var xml=new XmlDocument();xml.Load(Path.Combine(root,"AppxManifest.xml"));
            var identity=xml.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']");
            return identity.Attributes["Name"].Value=="OpenAI.Codex"&&identity.Attributes["Publisher"].Value=="CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B";
        }catch{return false;}
    }
    private static int VerifyPort(int port,string exe,string output,int expectedPid) {
        int owner=0;
        try {
            if(!OfficialExe(exe)){JsonResult(output,"untrusted-executable",false,0,IntPtr.Zero);return 4;}
            foreach(int family in new[]{2,23}) {
                int size=0; GetExtendedTcpTable(IntPtr.Zero,ref size,false,family,3,0);
                IntPtr buffer=Marshal.AllocHGlobal(size);
                try {
                    if(GetExtendedTcpTable(buffer,ref size,false,family,3,0)!=0)throw new InvalidOperationException("tcp-table-query-failed");
                    int count=Marshal.ReadInt32(buffer),stride=family==2?24:56;
                    for(int i=0;i<count;i++){
                        IntPtr row=IntPtr.Add(buffer,4+i*stride);
                        uint encoded=(uint)Marshal.ReadInt32(row,family==2?8:20);
                        if((ushort)IPAddress.NetworkToHostOrder((short)(encoded&65535))!=port)continue;
                        int pid=Marshal.ReadInt32(row,family==2?20:52);
                        if(family!=2||Marshal.ReadInt32(row,4)!=0x0100007f||(expectedPid>0&&pid!=expectedPid))throw new InvalidOperationException("untrusted-listener");
                        using(var p=Process.GetProcessById(pid))if(!String.Equals(Path.GetFullPath(p.MainModule.FileName),Path.GetFullPath(exe),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("unexpected-listener-owner");
                        if(owner!=0&&owner!=pid)throw new InvalidOperationException("ambiguous-listener");owner=pid;
                    }
                }finally{Marshal.FreeHGlobal(buffer);}
            }
            JsonResult(output,owner>0?"verified-listener":"no-listener",owner>0,owner,IntPtr.Zero);return owner>0?0:3;
        }catch(Exception e){JsonResult(output,e.Message=="untrusted-listener"||e.Message=="unexpected-listener-owner"||e.Message=="ambiguous-listener"?e.Message:"tcp-owner-query-failed",false,owner,IntPtr.Zero);return 4;}
    }
    private static void Rescue(string signal, int appPid, long started, int gatePid, string exe) {
        var time = Stopwatch.StartNew();
        while (time.Elapsed.TotalSeconds < 23) {
            if (File.Exists(signal + ".done")) return;
            bool gateAlive;
            try { using (var p = Process.GetProcessById(gatePid)) gateAlive = !p.HasExited; } catch { gateAlive = false; }
            if (!gateAlive) break;
            Thread.Sleep(100);
        }
        if (!SameApp(appPid, started, exe)) return;
        try { File.WriteAllText(signal + ".abort", "independent-watchdog"); } catch {}
        for (int attempt = 0; attempt < 10; attempt++) {
            try {
                foreach (string line in File.ReadAllLines(signal + ".windows")) {
                    var w = SavedWindow.Parse(line);
                    uint pid;
                    GetWindowThreadProcessId(w.Handle, out pid);
                    if (pid == (uint)appPid && SameApp(appPid, started, exe)) Restore(w);
                }
            } catch {}
            // No record means the gate had not changed this HWND's opacity.
            // Still show its main window if startup's SW_HIDE was honored.
            ShowUnrecordedMainWindows(appPid, started, exe);
            if (File.Exists(signal + ".done")) break;
            Thread.Sleep(100);
        }
        try { File.WriteAllText(signal + ".shown", "watchdog-restored"); } catch {}
    }
    [STAThread] private static int Main(string[] args) {
        try {
            if(args.Length==4&&args[0]=="--status"){
                int pid=int.Parse(args[1]);string exe=Path.GetFullPath(args[2]);
                if(!OfficialExe(exe)){JsonResult(args[3],"untrusted-executable",false,pid,IntPtr.Zero);return 4;}
                using(var p=Process.GetProcessById(pid))if(!SameApp(pid,p.StartTime.ToUniversalTime().Ticks,exe))return 4;
                JsonResult(args[3],"window-status",true,pid,MainWindow(pid));return 0;
            }
            if(args.Length==5&&args[0]=="--verify-port")return VerifyPort(int.Parse(args[1]),args[2],args[3],int.Parse(args[4]));
            if(args.Length==4&&args[0]=="--activate") {
                int pid=int.Parse(args[1]);string exe=Path.GetFullPath(args[2]);
                if(!OfficialExe(exe)){JsonResult(args[3],"untrusted-executable",false,pid,IntPtr.Zero);return 4;}
                long started;using(var p=Process.GetProcessById(pid))started=p.StartTime.ToUniversalTime().Ticks;
                IntPtr hwnd=ForegroundOwnedMain(pid,started,exe,3000);
                JsonResult(args[3],hwnd!=IntPtr.Zero?"foreground-confirmed":"foreground-not-confirmed",hwnd!=IntPtr.Zero,pid,hwnd);return hwnd!=IntPtr.Zero?0:5;
            }
            if (args.Length == 6 && args[0] == "--watchdog") { Rescue(args[1], int.Parse(args[2]), long.Parse(args[3]), int.Parse(args[4]), args[5]); return 0; }
            if (args.Length != 3) return 2;
            try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {}
            Application.EnableVisualStyles();
            Application.Run(new StartupGate(args[0], args[1], args[2]));
            return 0;
        } catch { return 1; }
    }
}
