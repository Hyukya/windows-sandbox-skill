using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Drawing;
using System.Drawing.Imaging;

// Secure-desktop support for Windows Sandbox.
//   Spawn : launched by a SYSTEM scheduled task (session 0). Duplicates the SYSTEM token,
//           retargets it to the interactive session and starts the helper there, attached
//           to winsta0\Winlogon so it can reach the secure desktop.
//   SW    : the helper's per-request primitives. Every op runs on a fresh window-less thread
//           that attaches to the CURRENT input desktop first (SetThreadDesktop fails with
//           ERROR_BUSY/170 on a thread that owns a window, e.g. the PowerShell host thread),
//           then captures (BitBlt) or injects input (SendInput) on that desktop.
public static class SbxSecure
{
    // ------------------------------------------------------------- Spawn (SYSTEM -> session)
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Lo; public int Hi; }
    [StructLayout(LayoutKind.Sequential)] struct TOKPRIV { public uint Count; public LUID Luid; public uint Attr; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string reserved; public string desktop; public string title;
        public int x, y, w, h, cx, cy, fill, flags; public short show, r2; public IntPtr r3, stdIn, stdOut, stdErr; }
    [StructLayout(LayoutKind.Sequential)] struct PROCINFO { public IntPtr hProcess, hThread; public int pid, tid; }

    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr t, uint a, IntPtr sa, int lvl, int type, out IntPtr n);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref int v, int len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string s, string n, out LUID l);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TOKPRIV n, int l, IntPtr p, IntPtr r);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr t, string app, string cmd, IntPtr pa, IntPtr ta, bool inh, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCINFO pi);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static void EnablePriv(IntPtr t, string name)
    {
        LUID l; if (!LookupPrivilegeValue(null, name, out l)) return;
        TOKPRIV tp = new TOKPRIV(); tp.Count = 1; tp.Luid = l; tp.Attr = 0x2; // SE_PRIVILEGE_ENABLED
        AdjustTokenPrivileges(t, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }

    // Start `commandLine` in `session` on `winsta0\desktop`. Returns the child pid. Call as SYSTEM.
    public static int StartInSession(int session, string desktop, string commandLine)
    {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0xF01FF, out tok)) throw new Exception("OpenProcessToken " + Marshal.GetLastWin32Error());
        try
        {
            EnablePriv(tok, "SeTcbPrivilege");
            EnablePriv(tok, "SeAssignPrimaryTokenPrivilege");
            EnablePriv(tok, "SeIncreaseQuotaPrivilege");
            IntPtr dup;
            if (!DuplicateTokenEx(tok, 0x02000000 /*MAXIMUM_ALLOWED*/, IntPtr.Zero, 2 /*Impersonation*/, 1 /*Primary*/, out dup))
                throw new Exception("DuplicateTokenEx " + Marshal.GetLastWin32Error());
            try
            {
                int sid = session;
                if (!SetTokenInformation(dup, 12 /*TokenSessionId*/, ref sid, 4)) throw new Exception("SetTokenInformation " + Marshal.GetLastWin32Error());
                STARTUPINFO si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO)); si.desktop = "winsta0\\" + desktop;
                PROCINFO pi;
                if (!CreateProcessAsUser(dup, null, commandLine, IntPtr.Zero, IntPtr.Zero, false, 0x08000000 /*CREATE_NO_WINDOW*/, IntPtr.Zero, null, ref si, out pi))
                    throw new Exception("CreateProcessAsUser " + Marshal.GetLastWin32Error());
                CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
                return pi.pid;
            }
            finally { CloseHandle(dup); }
        }
        finally { CloseHandle(tok); }
    }

    // ------------------------------------------------------------- SW (desktop worker)
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint f, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr h, int i, StringBuilder b, int l, out int n);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern short VkKeyScan(char c);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr d, int dx, int dy, int w, int h, IntPtr s, int sx, int sy, int rop);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr ex; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr ex; }

    const uint KEYUP = 0x2, UNICODE = 0x4, EXTENDED = 0x1;
    static int ISZ { get { return Marshal.SizeOf(typeof(INPUT)); } }

    // Run `body` on a fresh window-less MTA thread attached to the current input desktop.
    static string OnInputDesktop(Action body)
    {
        string desk = null, err = null;
        Thread t = new Thread(delegate ()
        {
            IntPtr h = OpenInputDesktop(0, false, 0x01FF);
            if (h == IntPtr.Zero) { err = "OpenInputDesktop " + Marshal.GetLastWin32Error(); return; }
            if (!SetThreadDesktop(h)) { err = "SetThreadDesktop " + Marshal.GetLastWin32Error(); CloseDesktop(h); return; }
            StringBuilder sb = new StringBuilder(256); int n; GetUserObjectInformation(h, 2, sb, 512, out n); desk = sb.ToString();
            try { body(); } catch (Exception e) { err = e.Message; } finally { CloseDesktop(h); }
        });
        t.IsBackground = true; t.SetApartmentState(ApartmentState.MTA); t.Start(); t.Join();
        if (err != null) throw new Exception(err + " (desktop=" + (desk ?? "?") + ")");
        return desk;
    }

    // Name of the current input desktop (Default, Winlogon, ...). Safe to call from any desktop.
    public static string InputDesktop()
    {
        IntPtr h = OpenInputDesktop(0, false, 0x0001 /*DESKTOP_READOBJECTS*/);
        if (h == IntPtr.Zero) return null;
        StringBuilder sb = new StringBuilder(256); int n; GetUserObjectInformation(h, 2, sb, 512, out n); CloseDesktop(h);
        return sb.ToString();
    }

    public static string Capture(string path)
    {
        return OnInputDesktop(delegate ()
        {
            int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
            IntPtr sdc = GetDC(IntPtr.Zero), mdc = CreateCompatibleDC(sdc), bmp = CreateCompatibleBitmap(sdc, w, h);
            IntPtr old = SelectObject(mdc, bmp);
            BitBlt(mdc, 0, 0, w, h, sdc, 0, 0, 0x00CC0020 /*SRCCOPY*/);
            SelectObject(mdc, old);
            using (Bitmap b = Image.FromHbitmap(bmp)) b.Save(path, ImageFormat.Png);
            DeleteObject(bmp); DeleteDC(mdc); ReleaseDC(IntPtr.Zero, sdc);
        });
    }

    static INPUT Mouse(uint f, uint data) { INPUT i = new INPUT(); i.type = 0; i.u.mi.flags = f; i.u.mi.data = data; return i; }
    static INPUT KeyVk(ushort vk, bool up) { INPUT i = new INPUT(); i.type = 1; i.u.ki.vk = vk; i.u.ki.flags = (up ? KEYUP : 0) | (IsExtended(vk) ? EXTENDED : 0); return i; }
    static INPUT KeyUni(char c, bool up) { INPUT i = new INPUT(); i.type = 1; i.u.ki.scan = c; i.u.ki.flags = UNICODE | (up ? KEYUP : 0); return i; }
    static bool IsExtended(ushort vk)
    {
        switch (vk) { case 0x21: case 0x22: case 0x23: case 0x24: case 0x25: case 0x26: case 0x27: case 0x28:
            case 0x2D: case 0x2E: case 0x5B: case 0x5C: case 0x5D: case 0x6F: case 0x90: case 0xA3: case 0xA5: case 0x2C: return true; }
        return false;
    }

    public static string Click(int x, int y, string button, int count)
    {
        uint dn, up; uint data = 0;
        switch ((button ?? "left").ToLowerInvariant())
        {
            case "right": dn = 0x0008; up = 0x0010; break;
            case "middle": dn = 0x0020; up = 0x0040; break;
            default: dn = 0x0002; up = 0x0004; break;
        }
        return OnInputDesktop(delegate ()
        {
            SetCursorPos(x, y); Thread.Sleep(40);
            for (int i = 0; i < Math.Max(1, count); i++)
            {
                SendInput(1, new[] { Mouse(dn, data) }, ISZ); Thread.Sleep(20);
                SendInput(1, new[] { Mouse(up, data) }, ISZ);
                if (i < count - 1) Thread.Sleep(60);
            }
        });
    }

    public static string Move(int x, int y) { return OnInputDesktop(delegate () { SetCursorPos(x, y); }); }

    public static string TypeText(string s)
    {
        return OnInputDesktop(delegate ()
        {
            foreach (char c in s)
            {
                if (c == '\r') continue;
                if (c == '\n') { SendInput(1, new[] { KeyVk(0x0D, false) }, ISZ); SendInput(1, new[] { KeyVk(0x0D, true) }, ISZ); }
                else if (c == '\t') { SendInput(1, new[] { KeyVk(0x09, false) }, ISZ); SendInput(1, new[] { KeyVk(0x09, true) }, ISZ); }
                else { SendInput(1, new[] { KeyUni(c, false) }, ISZ); SendInput(1, new[] { KeyUni(c, true) }, ISZ); }
            }
        });
    }

    // One chord: all vks down in order, then up in reverse.
    public static string Chord(ushort[] vks)
    {
        return OnInputDesktop(delegate ()
        {
            for (int i = 0; i < vks.Length; i++) SendInput(1, new[] { KeyVk(vks[i], false) }, ISZ);
            for (int i = vks.Length - 1; i >= 0; i--) SendInput(1, new[] { KeyVk(vks[i], true) }, ISZ);
        });
    }

    public static short CharToVk(char c) { return VkKeyScan(c); }
}
