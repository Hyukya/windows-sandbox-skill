using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class SbxNative
{
    // ---------------- structs ----------------
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x1, KEYEVENTF_KEYUP = 0x2, KEYEVENTF_UNICODE = 0x4;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x2, MOUSEEVENTF_LEFTUP = 0x4, MOUSEEVENTF_RIGHTDOWN = 0x8, MOUSEEVENTF_RIGHTUP = 0x10,
                      MOUSEEVENTF_MIDDLEDOWN = 0x20, MOUSEEVENTF_MIDDLEUP = 0x40, MOUSEEVENTF_XDOWN = 0x80, MOUSEEVENTF_XUP = 0x100,
                      MOUSEEVENTF_WHEEL = 0x800, MOUSEEVENTF_HWHEEL = 0x1000;

    // ---------------- imports ----------------
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int cb);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern short VkKeyScan(char ch);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hgt, bool repaint);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);

    // ---------------- helpers ----------------
    public static int InputSize() { return Marshal.SizeOf(typeof(INPUT)); }

    public static void MakeDpiAware()
    {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    static uint Send(List<INPUT> list)
    {
        if (list.Count == 0) return 0;
        uint r = SendInput((uint)list.Count, list.ToArray(), InputSize());
        if (r != list.Count) throw new Exception("SendInput sent " + r + "/" + list.Count + " events (Win32 error " + Marshal.GetLastWin32Error() + "). Target may be elevated or on the secure desktop.");
        return r;
    }

    static INPUT Mouse(uint flags, uint data)
    {
        INPUT i = new INPUT(); i.type = INPUT_MOUSE; i.U.mi.dwFlags = flags; i.U.mi.mouseData = data; return i;
    }

    static INPUT Key(ushort vk, ushort scan, uint flags)
    {
        INPUT i = new INPUT(); i.type = INPUT_KEYBOARD; i.U.ki.wVk = vk; i.U.ki.wScan = scan; i.U.ki.dwFlags = flags; return i;
    }

    static bool IsExtended(ushort vk)
    {
        switch (vk)
        {
            case 0x21: case 0x22: case 0x23: case 0x24: case 0x25: case 0x26: case 0x27: case 0x28: // pgup..down
            case 0x2D: case 0x2E: // insert delete
            case 0x5B: case 0x5C: case 0x5D: // lwin rwin apps
            case 0x6F: case 0x90: case 0xA3: case 0xA5: case 0x2C: // divide numlock rctrl ralt printscreen
                return true;
        }
        return false;
    }

    public static void MouseButton(string button, bool down)
    {
        uint f; uint data = 0;
        switch ((button ?? "left").ToLowerInvariant())
        {
            case "right": f = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP; break;
            case "middle": f = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP; break;
            case "x1": f = down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP; data = 1; break;
            case "x2": f = down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP; data = 2; break;
            default: f = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP; break;
        }
        Send(new List<INPUT> { Mouse(f, data) });
    }

    public static void Wheel(int clicks, bool horizontal)
    {
        Send(new List<INPUT> { Mouse(horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL, unchecked((uint)(clicks * 120))) });
    }

    public static void KeyEvent(ushort vk, bool down)
    {
        uint f = down ? 0 : KEYEVENTF_KEYUP;
        if (IsExtended(vk)) f |= KEYEVENTF_EXTENDEDKEY;
        Send(new List<INPUT> { Key(vk, 0, f) });
    }

    public static void Chord(ushort[] vks)
    {
        var l = new List<INPUT>();
        foreach (var vk in vks) l.Add(Key(vk, 0, IsExtended(vk) ? KEYEVENTF_EXTENDEDKEY : 0));
        for (int i = vks.Length - 1; i >= 0; i--) l.Add(Key(vks[i], 0, KEYEVENTF_KEYUP | (IsExtended(vks[i]) ? KEYEVENTF_EXTENDEDKEY : 0)));
        Send(l);
    }

    // Returns vk in low byte, shift state in high byte (VkKeyScan semantics); -1 if none.
    public static short CharToVk(char c) { return VkKeyScan(c); }

    public static void TypeText(string text, int delayMs)
    {
        var batch = new List<INPUT>();
        foreach (char c in text)
        {
            if (c == '\r') continue;
            if (c == '\n') { batch.Add(Key(0x0D, 0, 0)); batch.Add(Key(0x0D, 0, KEYEVENTF_KEYUP)); }
            else if (c == '\t') { batch.Add(Key(0x09, 0, 0)); batch.Add(Key(0x09, 0, KEYEVENTF_KEYUP)); }
            else { batch.Add(Key(0, c, KEYEVENTF_UNICODE)); batch.Add(Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)); }
            if (delayMs > 0 || batch.Count >= 200) { Send(batch); batch.Clear(); if (delayMs > 0) System.Threading.Thread.Sleep(delayMs); }
        }
        Send(batch);
    }

    public static string WindowText(IntPtr h)
    {
        int n = GetWindowTextLength(h); var sb = new StringBuilder(n + 2); GetWindowText(h, sb, sb.Capacity); return sb.ToString();
    }
    public static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }

    // SetWindowDisplayAffinity value of a window: 0 none, 1 WDA_MONITOR (black in captures),
    // 0x11 WDA_EXCLUDEFROMCAPTURE (missing from captures). 0 when it cannot be read.
    [DllImport("user32.dll")] static extern bool GetWindowDisplayAffinity(IntPtr h, out uint affinity);
    public static uint DisplayAffinity(IntPtr h) { uint a; return GetWindowDisplayAffinity(h, out a) ? a : 0; }

    public static IntPtr[] TopWindows(bool includeHidden)
    {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            if (includeHidden || (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero /*no owner*/ && GetWindowTextLength(h) > 0)) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    public static bool Focus(IntPtr h)
    {
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        IntPtr fg = GetForegroundWindow();
        uint dummy;
        uint fgThread = GetWindowThreadProcessId(fg, out dummy);
        uint me = GetCurrentThreadId();
        // Alt tap unlocks SetForegroundWindow restrictions
        try { Chord(new ushort[] { 0x12 }); } catch { }
        bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        BringWindowToTop(h);
        bool ok = SetForegroundWindow(h);
        if (attached) AttachThreadInput(me, fgThread, false);
        return ok || GetForegroundWindow() == h;
    }
}
