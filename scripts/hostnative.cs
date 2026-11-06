using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

// Host-side helpers for sbx.ps1: find the Windows Sandbox window and capture it from outside the VM.
public static class SbxHost
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);

    // The guest display inside the sandbox window: the RDP client's "Output Painter Window" (OPContainerClass),
    // else its "Input Capture Window" (IHWindowClass). IntPtr.Zero if neither exists (older/other clients).
    public static IntPtr FindDisplay(IntPtr top)
    {
        IntPtr painter = IntPtr.Zero, input = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            if (!IsWindowVisible(h)) return true;
            string c = ClassOf(h);
            if (c == "OPContainerClass" && painter == IntPtr.Zero) painter = h;
            else if (c == "IHWindowClass" && input == IntPtr.Zero) input = h;
            return true;
        }, IntPtr.Zero);
        return painter != IntPtr.Zero ? painter : input;
    }

    public static void MakeDpiAware()
    {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    public static string WindowText(IntPtr h) { int n = GetWindowTextLength(h); var sb = new StringBuilder(n + 2); GetWindowText(h, sb, sb.Capacity); return sb.ToString(); }
    public static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
    public static uint PidOf(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return pid; }

    // visible, unowned top-level windows of the given processes
    public static IntPtr[] WindowsOf(int[] pids)
    {
        var set = new HashSet<uint>(); foreach (var p in pids) set.Add((uint)p);
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            if (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && set.Contains(PidOf(h))) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    // visible frame without the invisible resize borders (DWMWA_EXTENDED_FRAME_BOUNDS), falls back to GetWindowRect
    public static RECT FrameRect(IntPtr h)
    {
        RECT r;
        if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) == 0 && r.Right > r.Left) return r;
        GetWindowRect(h, out r); return r;
    }

    public static RECT ClientScreenRect(IntPtr h)
    {
        RECT c; GetClientRect(h, out c);
        POINT p = new POINT(); ClientToScreen(h, ref p);
        RECT r; r.Left = p.X; r.Top = p.Y; r.Right = p.X + c.Right; r.Bottom = p.Y + c.Bottom; return r;
    }

    public static void Activate(IntPtr h)
    {
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); // Alt tap unlocks SetForegroundWindow
        BringWindowToTop(h); SetForegroundWindow(h);
    }

    // Renders the whole window (incl. frame) with PrintWindow(PW_RENDERFULLCONTENT). Works while occluded/off-screen,
    // not while minimized. Returned bitmap's origin = GetWindowRect(h).TopLeft.
    public static Bitmap CapturePrint(IntPtr h)
    {
        RECT r; GetWindowRect(h, out r);
        int w = r.Right - r.Left, hh = r.Bottom - r.Top;
        if (w <= 0 || hh <= 0) throw new Exception("window has no area");
        var bmp = new Bitmap(w, hh, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            IntPtr hdc = g.GetHdc();
            bool ok;
            try { ok = PrintWindow(h, hdc, 2); } finally { g.ReleaseHdc(hdc); }
            if (!ok) { bmp.Dispose(); throw new Exception("PrintWindow failed"); }
        }
        return bmp;
    }

    public static Bitmap CaptureScreen(int x, int y, int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
        return bmp;
    }

    public static Bitmap Crop(Bitmap src, int x, int y, int w, int h)
    {
        x = Math.Max(0, x); y = Math.Max(0, y);
        w = Math.Min(w, src.Width - x); h = Math.Min(h, src.Height - y);
        if (w <= 0 || h <= 0) throw new Exception("crop outside the captured image");
        return src.Clone(new Rectangle(x, y, w, h), src.PixelFormat);
    }

    // true if (almost) every sampled pixel has the same color - typical of a failed/blank capture
    public static bool LooksBlank(Bitmap b)
    {
        int stepX = Math.Max(1, b.Width / 40), stepY = Math.Max(1, b.Height / 40);
        int first = b.GetPixel(b.Width / 2, b.Height / 2).ToArgb() & 0xFFFFFF;
        int same = 0, total = 0;
        for (int y = stepY / 2; y < b.Height; y += stepY)
            for (int x = stepX / 2; x < b.Width; x += stepX)
            {
                total++;
                if ((b.GetPixel(x, y).ToArgb() & 0xFFFFFF) == first) same++;
            }
        return total > 0 && same >= total * 0.995;
    }
}
