// Pacific Together launcher. C# 5 (the .NET Framework csc every Windows has), WinForms, no dependencies.
// Install logic stays in install.ps1; this app only drives it and shows the bundled texts. A release is this one exe: the whole
// package (install.ps1, the docs, game/) is embedded as payload.zip and unpacked once per version to %LOCALAPPDATA%\PacificTogether\app.
// Test flags: --shot <png> [--tab 0-3] [--scale 1.5] renders the window to a PNG and exits.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

static class Pal
{
    public static readonly Color Bg = Color.FromArgb(0x12, 0x17, 0x1A), Panel = Color.FromArgb(0x1A, 0x21, 0x25),
        Edge = Color.FromArgb(0x35, 0x42, 0x46), Text = Color.FromArgb(0xE2, 0xDD, 0xCC), Dim = Color.FromArgb(0x95, 0xA3, 0xA0),
        Teal = Color.FromArgb(0x5C, 0xB5, 0xAC), Amber = Color.FromArgb(0xE6, 0xAE, 0x3E), Rust = Color.FromArgb(0xD0, 0x6A, 0x45);
}

static class UI
{
    public static float Px = 1f;     // device pixels per 96-dpi pixel, times the test scale
    public static float Pt = 1f;     // test scale for font sizes (the OS scales points by itself)
    public static int S(int v) { return (int)Math.Round(v * Px); }
    public static Font Head(float pt, bool bold) { return Make("Bahnschrift SemiBold", "Segoe UI Semibold", pt, bold ? FontStyle.Bold : FontStyle.Regular); }
    public static Font Body(float pt) { return Make("Segoe UI", "Arial", pt, FontStyle.Regular); }
    public static Font Mono(float pt) { return Make("Consolas", "Courier New", pt, FontStyle.Regular); }
    static Font Make(string a, string b, float pt, FontStyle st)
    {
        var f = new Font(a, pt * Pt, st);
        return f.Name.Equals(a, StringComparison.OrdinalIgnoreCase) ? f : new Font(b, pt * Pt, st);
    }
}

enum Kind { Normal, Primary, Danger, Tab }

class PtButton : Button
{
    public Kind K = Kind.Normal;
    public bool Selected;
    bool hover, down;
    public PtButton(string text, Kind k)
    {
        K = k; Text = text; FlatStyle = FlatStyle.Flat; UseMnemonic = true;
        Font = k == Kind.Tab ? UI.Head(11.5f, false) : UI.Head(10f, false);
        SetStyle(ControlStyles.Selectable | ControlStyles.UserPaint, true);
        MouseEnter += delegate { hover = true; Invalidate(); };
        MouseLeave += delegate { hover = false; down = false; Invalidate(); };
        MouseDown += delegate { down = true; Invalidate(); };
        MouseUp += delegate { down = false; Invalidate(); };
        GotFocus += delegate { Invalidate(); };
        LostFocus += delegate { Invalidate(); };
        Cursor = Cursors.Hand; AccessibleRole = AccessibleRole.PushButton;
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; var r = new Rectangle(0, 0, Width - 1, Height - 1);
        Color fill = Pal.Bg, fg = Pal.Text, border = Pal.Edge;
        if (K == Kind.Primary) { fill = down ? Color.FromArgb(0xB8, 0x86, 0x28) : hover ? Color.FromArgb(0xF2, 0xBD, 0x58) : Pal.Amber; fg = Color.FromArgb(0x1B, 0x14, 0x06); border = fill; }
        else if (K == Kind.Danger) { fg = Pal.Rust; border = Pal.Rust; if (hover) fill = Color.FromArgb(0x2A, 0x1C, 0x18); }
        else if (K == Kind.Tab) { border = Pal.Bg; fg = Selected ? Pal.Amber : hover ? Pal.Text : Pal.Dim; }
        else if (hover) { fill = Pal.Panel; border = Pal.Dim; }
        if (!Enabled) { fg = Color.FromArgb(0x5E, 0x69, 0x68); border = Pal.Edge; if (K == Kind.Primary) fill = Pal.Panel; }
        using (var b = new SolidBrush(fill)) g.FillRectangle(b, 0, 0, Width, Height);
        if (K != Kind.Tab) using (var p = new Pen(border)) g.DrawRectangle(p, r);
        if (K == Kind.Tab && Selected) using (var b = new SolidBrush(Pal.Amber)) g.FillRectangle(b, 0, Height - UI.S(3), Width, UI.S(3));
        var flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | (ShowKeyboardCues ? 0 : TextFormatFlags.HidePrefix);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), fg, flags);
        if (Focused && ShowFocusCues) using (var p = new Pen(Pal.Teal, Math.Max(2, UI.S(2)))) g.DrawRectangle(p, UI.S(2), UI.S(2), Width - 1 - UI.S(4), Height - 1 - UI.S(4));
    }
}

class Header : Control
{
    public string Version = "";
    public Header() { SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using (var b = new SolidBrush(Pal.Panel)) g.FillRectangle(b, ClientRectangle);
        int pad = UI.S(24);
        using (var f = UI.Head(24f, false))
            TextRenderer.DrawText(g, "PACIFIC TOGETHER", f, new Point(pad, UI.S(10)), Pal.Text, TextFormatFlags.NoPadding);
        using (var f = UI.Body(9f))
            TextRenderer.DrawText(g, "TWO-PLAYER CO-OP FOR PACIFIC DRIVE  ·  ONLINE  ·  DEV PREVIEW", f, new Point(pad + UI.S(2), UI.S(52)), Pal.Teal, TextFormatFlags.NoPadding);
        using (var f = UI.Mono(9.5f))
        {
            var sz = TextRenderer.MeasureText(g, Version, f);
            var box = new Rectangle(Width - pad - sz.Width - UI.S(16), UI.S(22), sz.Width + UI.S(16), sz.Height + UI.S(8));
            using (var p = new Pen(Pal.Amber, Math.Max(1, UI.S(1)))) g.DrawRectangle(p, box);
            TextRenderer.DrawText(g, Version, f, new Point(box.X + UI.S(8), box.Y + UI.S(4)), Pal.Amber, TextFormatFlags.NoPadding);
        }
        // the road's centre line: dashed amber, the one thing on the screen that is pure Pacific Northwest back road
        using (var p = new Pen(Pal.Amber, Math.Max(2, UI.S(3))) { DashPattern = new float[] { 5f, 3f } })
            g.DrawLine(p, 0, Height - UI.S(4), Width, Height - UI.S(4));
    }
}

class DocView : RichTextBox
{
    public DocView()
    {
        ReadOnly = true; BorderStyle = BorderStyle.None; BackColor = Pal.Panel; ForeColor = Pal.Text; Font = UI.Body(10.5f);
        DetectUrls = false; TabStop = true; ScrollBars = RichTextBoxScrollBars.Vertical;
        LinkClicked += delegate (object s, LinkClickedEventArgs a) { try { Process.Start(a.LinkText); } catch { } };
    }
    void Add(string text, Font f, Color c, int indent, int hang, int before)
    {
        if (before > 0 && TextLength > 0) { SelectionStart = TextLength; SelectionFont = UI.Body(before); AppendText("\n"); }
        int at = TextLength;
        AppendText(text + "\n");
        Select(at, TextLength - at);  // format the finished paragraph; formatting before AppendText lost wrapped lines
        SelectionFont = f; SelectionColor = c; SelectionIndent = indent; SelectionHangingIndent = 0; SelectionBullet = hang > 0; if (hang > 0) BulletIndent = UI.S(12);
        SelectionLength = 0;
    }
    static string Clean(string s)
    {
        s = Regex.Replace(s, @"\[([^\]]+)\]\(([^)]+)\)", "$1 ($2)");
        return s.Replace("**", "").Replace("`", "");
    }
    // minimal markdown: # ## ### headings, "- " bullets, blank-line separated paragraphs
    public void Render(string md)
    {
        Clear(); SuspendLayout();
        var joined = new List<string>();  // hard-wrapped source lines (indented, or plain after plain/bullet text) belong to the line above
        foreach (var raw in md.Replace("\r", "").Split('\n'))
        {
            var l = raw.TrimEnd();
            bool cont = l.Length > 0 && joined.Count > 0 && joined[joined.Count - 1].Length > 0 && !l.StartsWith("#") && !l.StartsWith("- ");
            if (cont) joined[joined.Count - 1] += " " + l.Trim(); else joined.Add(l);
        }
        foreach (var l in joined)
        {
            if (l.Length == 0) continue;
            if (l.StartsWith("### ")) Add(Clean(l.Substring(4)), UI.Head(11.5f, false), Pal.Teal, 0, 0, 6);
            else if (l.StartsWith("## ")) Add(Clean(l.Substring(3)), UI.Head(15f, false), Pal.Amber, 0, 0, 12);
            else if (l.StartsWith("# ")) Add(Clean(l.Substring(2)), UI.Head(20f, false), Pal.Text, 0, 0, 0);
            else if (l.StartsWith("- ")) Add(Clean(l.Substring(2)), UI.Body(10.5f), Pal.Text, UI.S(22), 1, 0);
            else Add(Clean(l), UI.Body(10.5f), Pal.Dim, 0, 0, 0);
        }
        SelectionStart = 0; ScrollToCaret(); ResumeLayout();
    }
}

class App : Form
{
    public static string baseDir = AppDomain.CurrentDomain.BaseDirectory;  // the unpacked payload, or the exe's folder in a dev build
    static readonly string Data = Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "", "PacificTogether");
    static readonly string Archive = Path.Combine(Data, "logs");  // UE4SS.log of earlier runs (the game empties it at every start)
    readonly string settingsFile = Path.Combine(Environment.GetEnvironmentVariable("APPDATA") ?? "", @"PacificTogether\launcher.txt");  // line 1 folder, 2 IP, 3 host|join
    TextBox folder, ip, output;
    RadioButton rHost, rJoin;
    Label status, versions;
    PtButton install, uninstall, openLogs, collect, browse;
    readonly List<PtButton> tabs = new List<PtButton>();
    readonly List<Control> pages = new List<Control>();
    bool busy;

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);

    static Label Cap(string t) { return new Label { Text = t, AutoSize = true, ForeColor = Pal.Dim, Font = UI.Head(9f, false), Margin = new Padding(0, UI.S(14), 0, UI.S(4)) }; }
    static TextBox Box() { return new TextBox { BackColor = Pal.Bg, ForeColor = Pal.Text, BorderStyle = BorderStyle.FixedSingle, Font = UI.Body(11f), Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 0) }; }

    public App(int startTab)
    {
        Text = "Pacific Together"; BackColor = Pal.Bg; ForeColor = Pal.Text; Font = UI.Body(10f);
        AutoScaleMode = AutoScaleMode.None; StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(UI.S(880), UI.S(660)); MinimumSize = new Size(UI.S(760), UI.S(620));

        var header = new Header { Dock = DockStyle.Top, Height = UI.S(86), Version = "v" + Regex.Replace(BundledVersion(), "^PacificTogether-", "") };
        var tabRow = new FlowLayoutPanel { Dock = DockStyle.Top, Height = UI.S(48), BackColor = Pal.Bg, Padding = new Padding(UI.S(16), UI.S(4), 0, 0), WrapContents = false };
        var foot = new Panel { Dock = DockStyle.Bottom, Height = UI.S(36), BackColor = Pal.Panel };
        versions = new Label { Dock = DockStyle.Fill, ForeColor = Pal.Dim, Font = UI.Mono(9f), TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(UI.S(24), 0, 0, 0) };
        foot.Controls.Add(versions);
        var body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(UI.S(24), UI.S(8), UI.S(24), UI.S(8)) };

        pages.Add(BuildPlay());
        var news = new DocView(); pages.Add(news);
        var limits = new DocView(); pages.Add(limits);
        var guide = new DocView(); pages.Add(guide);
        news.Render(ReadFile("CHANGELOG.md", "CHANGELOG.md is missing next to the app."));
        limits.Render(LimitsMarkdown());
        guide.Render(ReadFile("GUIDE.md", "GUIDE.md is missing next to the app."));

        string[] names = { "&Play", "What's &new", "&Known limitations", "Playtester &guide" };
        for (int i = 0; i < 4; i++)
        {
            int idx = i;
            var t = new PtButton(names[i], Kind.Tab) { Size = new Size(UI.S(i == 2 ? 190 : i == 3 ? 170 : i == 1 ? 130 : 80), UI.S(40)), Margin = new Padding(0, 0, UI.S(8), 0) };
            t.Click += delegate { ShowTab(idx); };
            tabs.Add(t); tabRow.Controls.Add(t);
            pages[i].Dock = DockStyle.Fill; body.Controls.Add(pages[i]);
        }
        Controls.Add(body); Controls.Add(tabRow); Controls.Add(header); Controls.Add(foot);
        AcceptButton = null;

        var wa = Screen.PrimaryScreen.WorkingArea;  // never taller than the screen at high scaling
        ClientSize = new Size(Math.Min(ClientSize.Width, wa.Width - UI.S(40)), Math.Min(ClientSize.Height, wa.Height - UI.S(80)));
        MinimumSize = new Size(Math.Min(MinimumSize.Width, Width), Math.Min(MinimumSize.Height, Height));
        Location = new Point(wa.Left + Math.Max(0, (wa.Width - Width) / 2), wa.Top + Math.Max(0, (wa.Height - Height) / 2));
        LoadSettings(); ShowTab(startTab); Refresh2();
        Shown += delegate { install.Focus(); };
        // while the launcher is open: each time the game has closed, its log is kept (a restart from Steam would empty it)
        bool wasRunning = false;
        var watch = new System.Windows.Forms.Timer { Interval = 5000 };
        watch.Tick += delegate { bool r = GameRunning(); if (wasRunning && !r && GameOk) ArchiveLog(); wasRunning = r; };
        watch.Start();
        folder.TextChanged += delegate { Refresh2(); };
        Load += delegate { int v = 1; try { DwmSetWindowAttribute(Handle, 20, ref v, 4); } catch { } };
    }

    void ShowTab(int i)
    {
        for (int k = 0; k < pages.Count; k++) { pages[k].Visible = k == i; tabs[k].Selected = k == i; tabs[k].Invalidate(); }
    }

    Control BuildPlay()
    {
        var t = new TableLayoutPanel { ColumnCount = 1, RowCount = 0, AutoScroll = false };
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Action<Control, SizeType, float> row = (c, st, h) => { t.RowStyles.Add(new RowStyle(st, h)); t.Controls.Add(c, 0, t.RowCount); t.RowCount++; c.Dock = c is Label ? DockStyle.None : DockStyle.Fill; };

        row(Cap("GAME FOLDER  (THE ONE WITH PENDRIVERPRO IN IT)"), SizeType.AutoSize, 0);
        var fr = new TableLayoutPanel { ColumnCount = 2, RowCount = 1, Height = UI.S(34), Margin = new Padding(0) };
        fr.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); fr.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, UI.S(110)));
        folder = Box(); folder.Margin = new Padding(0, 0, UI.S(8), 0);
        browse = new PtButton("&Browse...", Kind.Normal) { Dock = DockStyle.Fill, Margin = new Padding(0) };
        browse.Click += delegate
        {
            using (var d = new FolderBrowserDialog { Description = "Select the Pacific Drive folder", SelectedPath = folder.Text })
                if (d.ShowDialog(this) == DialogResult.OK) folder.Text = d.SelectedPath;
        };
        fr.Controls.Add(folder, 0, 0); fr.Controls.Add(browse, 1, 0);
        row(fr, SizeType.Absolute, UI.S(36));
        status = new Label { AutoSize = true, ForeColor = Pal.Dim, Margin = new Padding(0, UI.S(4), 0, 0) };
        row(status, SizeType.AutoSize, 0);

        row(Cap("HOW ARE YOU PLAYING?"), SizeType.AutoSize, 0);
        rHost = new RadioButton { Text = "I am the &host: I load my save and my friend joins me", AutoSize = true, ForeColor = Pal.Text, Checked = true, Margin = new Padding(0, 0, 0, UI.S(6)), Font = UI.Body(10.5f) };
        // both radios share one container so they exclude each other
        var jr = new TableLayoutPanel { ColumnCount = 2, RowCount = 2, Margin = new Padding(0) };
        jr.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); jr.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        jr.RowStyles.Add(new RowStyle(SizeType.Absolute, UI.S(32))); jr.RowStyles.Add(new RowStyle(SizeType.Absolute, UI.S(38)));
        rHost.Anchor = AnchorStyles.Left; jr.Controls.Add(rHost, 0, 0); jr.SetColumnSpan(rHost, 2);
        rJoin = new RadioButton { Text = "I am the &guest: join host address", AutoSize = true, ForeColor = Pal.Text, Anchor = AnchorStyles.Left, Margin = new Padding(0, 0, UI.S(12), 0), Font = UI.Body(10.5f) };
        ip = Box(); ip.Margin = new Padding(0); ip.Anchor = AnchorStyles.Left | AnchorStyles.Right; ip.Dock = DockStyle.None; ip.Width = UI.S(300);
        jr.Controls.Add(rJoin, 0, 1); jr.Controls.Add(ip, 1, 1);
        row(jr, SizeType.Absolute, UI.S(70));
        rJoin.CheckedChanged += delegate { ip.Enabled = rJoin.Checked; if (rJoin.Checked && !busy) ip.Focus(); };
        ip.Enabled = false;

        var bf = new FlowLayoutPanel { Height = UI.S(52), WrapContents = false, Margin = new Padding(0, UI.S(14), 0, 0) };
        install = new PtButton("In&stall && play", Kind.Primary) { Size = new Size(UI.S(190), UI.S(44)), Margin = new Padding(0, 0, UI.S(10), 0) };
        install.Font = UI.Head(12f, false);
        uninstall = new PtButton("&Uninstall", Kind.Danger) { Size = new Size(UI.S(110), UI.S(44)), Margin = new Padding(0, 0, UI.S(10), 0) };
        openLogs = new PtButton("Open &log folder", Kind.Normal) { Size = new Size(UI.S(150), UI.S(44)), Margin = new Padding(0, 0, UI.S(10), 0) };
        collect = new PtButton("&Copy logs", Kind.Normal) { Size = new Size(UI.S(130), UI.S(44)), Margin = new Padding(0) };
        bf.Controls.AddRange(new Control[] { install, uninstall, openLogs, collect });
        row(bf, SizeType.Absolute, UI.S(66));
        install.Click += delegate { DoInstall(); };
        uninstall.Click += delegate { DoUninstall(); };
        openLogs.Click += delegate { OpenLogs(); };
        collect.Click += delegate { CollectLogs(); };

        output = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BackColor = Pal.Panel, ForeColor = Pal.Dim, BorderStyle = BorderStyle.None, Font = UI.Mono(9.5f), Margin = new Padding(0, UI.S(6), 0, 0), Text = "Installer output shows up here." };
        row(output, SizeType.Percent, 100);
        t.Dock = DockStyle.Fill;
        return t;
    }

    // ---- paths and versions ----
    string Bin { get { return Path.Combine(folder.Text.Trim(), @"PenDriverPro\Binaries\Win64"); } }
    string Stamp(string root) { try { return File.ReadAllText(Path.Combine(root, @"ue4ss\Mods\PacificTogether\version.txt")).Trim(); } catch { return null; } }
    string BundledVersion() { return Stamp(Path.Combine(baseDir, "game")) ?? "dev"; }
    bool GameOk { get { return File.Exists(Path.Combine(Bin, "PenDriverPro-Win64-Shipping.exe")); } }

    void Refresh2()
    {
        bool ok = GameOk;
        status.Text = ok ? "Pacific Drive found." : "No Pacific Drive here. Browse to the folder that contains PenDriverPro.";
        status.ForeColor = ok ? Pal.Teal : Pal.Rust;
        var inst = ok ? Stamp(Bin) : null;
        var mine = BundledVersion();
        versions.Text = "This download: " + mine + "     Installed: " + (inst ?? "not installed") + (inst != null && inst != mine ? "  (will be updated)" : "");
    }

    string ReadFile(string name, string missing) { try { return File.ReadAllText(Path.Combine(baseDir, name), Encoding.UTF8); } catch { return missing; } }

    // source of truth stays tools/package/README.txt: its "What works" and "Not done yet" sections up to "Install and start"
    string LimitsMarkdown()
    {
        var txt = ReadFile("README.txt", null);
        if (txt == null) return "README.txt is missing next to the app.";
        var lines = txt.Replace("\r", "").Split('\n');
        int a = Array.FindIndex(lines, l => l.StartsWith("What works")), b = Array.FindIndex(lines, l => l.StartsWith("Install and start"));
        if (a < 0 || b < a) return string.Join("\n", lines);
        var sb = new StringBuilder("# Known limitations\n");
        for (int i = a; i < b; i++)
        {
            var l = lines[i];
            if (l.Trim().Length == 0) continue;
            if (l.StartsWith("- ")) sb.Append("\n").Append(l);
            else if (l.StartsWith(" ")) sb.Append(" ").Append(l.Trim());
            else sb.Append("\n## ").Append(l);
        }
        return sb.ToString();
    }

    // ---- settings ----
    void LoadSettings()
    {
        var s = new List<string>();
        try { s.AddRange(File.ReadAllLines(settingsFile)); } catch { }
        while (s.Count < 3) s.Add("");
        folder.Text = s[0].Length > 0 ? s[0] : FindGame();
        ip.Text = s[1];
        if (s[2] == "join" || (s[2] == "" && s[1] != "")) rJoin.Checked = true;
    }
    void SaveSettings()
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(settingsFile)); File.WriteAllLines(settingsFile, new[] { folder.Text.Trim(), ip.Text.Trim(), rJoin.Checked ? "join" : "host" }); } catch { }
    }
    string FindGame()
    {
        var script = Path.Combine(baseDir, "install.ps1");
        if (!File.Exists(script)) return "";
        var o = new StringBuilder();
        try { Run(script, "-Find", l => o.AppendLine(l), true); } catch { }
        return o.ToString().Trim().Split('\n').Last().Trim();
    }

    // ---- install.ps1 ----
    int Run(string script, string args, Action<string> line, bool wait)
    {
        var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" " + args)
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, WorkingDirectory = baseDir };
        using (var p = Process.Start(psi))
        {
            DataReceivedEventHandler h = (s, e) => { if (e.Data != null) line(e.Data); };
            p.OutputDataReceived += h; p.ErrorDataReceived += h;
            p.BeginOutputReadLine(); p.BeginErrorReadLine(); p.WaitForExit();
            return p.ExitCode;
        }
    }

    void Log(string s) { if (output.InvokeRequired) { output.BeginInvoke(new Action<string>(Log), s); return; } output.AppendText(s + "\r\n"); }

    void SetBusy(bool b)
    {
        busy = b; UseWaitCursor = b;
        foreach (var c in new[] { install, uninstall, collect, browse }) c.Enabled = !b;
    }

    static readonly Regex AddrOk = new Regex(@"^[A-Za-z0-9.:\-\[\]]{1,253}$");

    void Execute(string extra, string doneOk, bool launch)
    {
        var script = Path.Combine(baseDir, "install.ps1");
        if (!File.Exists(script)) { Fail("install.ps1 is missing next to the app. Unpack the whole zip first."); return; }
        if (!GameOk) { Fail("Pick the folder that contains PenDriverPro first."); return; }
        output.Clear(); SetBusy(true);
        var path = folder.Text.Trim();
        ThreadPool.QueueUserWorkItem(delegate
        {
            int code = -1;
            try { code = Run(script, "-GameDir \"" + path + "\" " + extra, Log, true); } catch (Exception ex) { Log("ERROR: " + ex.Message); }
            BeginInvoke(new Action(delegate
            {
                SetBusy(false); Refresh2();
                if (code != 0) { Fail("The installer stopped. Read its message in the box below."); return; }
                Log(doneOk);
                if (launch) StartGame();
            }));
        });
    }

    void Fail(string m) { MessageBox.Show(this, m, "Pacific Together", MessageBoxButtons.OK, MessageBoxIcon.Error); }

    // through Steam when it is installed (overlay, invites, its own launch checks), else the exe itself (steam_appid.txt lets it start)
    static string SteamExe()
    {
        try { var v = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamExe", null) as string; return v != null && File.Exists(v) ? v : null; }
        catch { return null; }
    }
    void StartGame()
    {
        ArchiveLog();
        try
        {
            if (SteamExe() != null) { Process.Start("steam://rungameid/1458140"); Log("Starting Pacific Drive through Steam."); }
            else { Process.Start(new ProcessStartInfo(Path.Combine(Bin, "PenDriverPro-Win64-Shipping.exe")) { WorkingDirectory = Bin }); Log("Starting Pacific Drive (Steam not found)."); }
        }
        catch (Exception ex) { Fail("Could not start the game: " + ex.Message); }
    }

    static bool GameRunning() { return Process.GetProcessesByName("PenDriverPro-Win64-Shipping").Length > 0; }
    // keeps a copy of UE4SS.log named after its last write (the game empties it at the next start); the newest 30 are kept
    void ArchiveLog()
    {
        try
        {
            var log = Path.Combine(Bin, @"ue4ss\UE4SS.log");
            if (!File.Exists(log) || new FileInfo(log).Length == 0) return;
            Directory.CreateDirectory(Archive);
            var dst = Path.Combine(Archive, "UE4SS-" + File.GetLastWriteTime(log).ToString("yyyyMMdd-HHmmss") + ".log");
            if (!File.Exists(dst)) CopyShared(log, dst);
            foreach (var old in new DirectoryInfo(Archive).GetFiles("UE4SS-*.log").OrderByDescending(f => f.Name).Skip(30)) old.Delete();
        }
        catch { }
    }

    void DoInstall()
    {
        var addr = ip.Text.Trim();
        if (rJoin.Checked && !AddrOk.IsMatch(addr)) { Fail("Type the host's address (for example 100.64.1.2) in the Join box."); ip.Focus(); return; }
        SaveSettings();
        Execute(rJoin.Checked ? "-Join \"" + addr + "\"" : "", "Done.", true);
    }

    void DoUninstall()
    {
        if (MessageBox.Show(this, "Remove UE4SS and the mod from this game folder?\nThis deletes the whole ue4ss folder, including other UE4SS mods. Your saves are not touched.",
            "Uninstall", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
        Execute("-Uninstall", "Done.", false);
    }

    // ---- logs ----
    void OpenLogs()
    {
        var d = Path.Combine(Bin, "ue4ss");
        if (!Directory.Exists(d)) { Fail("Nothing installed in this game folder yet, so there are no logs."); return; }
        Process.Start("explorer.exe", "\"" + d + "\"");
    }

    static void CopyShared(string src, string dst)
    {
        using (var i = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var o = new FileStream(dst, FileMode.Create)) i.CopyTo(o);
    }

    // Copy logs: everything a bug report needs from this PC in one Desktop zip (list.txt says what is in it):
    //   ue4ss/     UE4SS.log now, the launcher's copies of earlier runs, the mod's own run-01..10 logs (every run, however started),
    //              version, join address, performance check results, UE4SS settings
    //   engine/    the game's own logs of the last 7 days (PenDriverPro.log and its per-run backups)
    //   crashes/   crash folders of the last 7 days: our marker, the engine's native call stack, its log
    //   saves/     each slot's current save, backups of the last 2 days, the guest backpack side files, game settings
    //   system.txt OS, CPU, GPU, memory, game exe check, Steam, launcher version
    void CollectLogs()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "PacificTogether-logs-" + Guid.NewGuid().ToString("N"));
        var list = new StringBuilder();
        try
        {
            if (!GameRunning()) ArchiveLog();
            Directory.CreateDirectory(tmp);
            int n = 0;
            Action<string, string> take = (src, rel) =>
            {
                try
                {
                    if (!File.Exists(src)) return;
                    var dst = Path.Combine(tmp, rel);
                    Directory.CreateDirectory(Path.GetDirectoryName(dst));
                    CopyShared(src, dst); n++;
                    list.AppendLine(string.Format("{0,10:N0}  {1:yyyy-MM-dd HH:mm}  {2}", new FileInfo(src).Length, File.GetLastWriteTime(src), rel));
                }
                catch (Exception ex) { list.AppendLine("  (could not copy " + rel + ": " + ex.Message + ")"); }
            };
            var week = DateTime.Now.AddDays(-7);
            var mod = Path.Combine(Bin, @"ue4ss\Mods\PacificTogether");
            take(Path.Combine(Bin, @"ue4ss\UE4SS.log"), @"ue4ss\UE4SS.log");
            if (Directory.Exists(Archive)) foreach (var f in Directory.GetFiles(Archive, "UE4SS-*.log")) take(f, @"ue4ss\earlier\" + Path.GetFileName(f));
            if (Directory.Exists(mod))
                foreach (var f in Directory.GetFiles(mod).Where(f => Regex.IsMatch(Path.GetFileName(f), @"^(run-\d+\.log|runs\.txt|version\.txt|join\.txt|performance\.txt)$")))
                    take(f, @"ue4ss\" + Path.GetFileName(f));
            take(Path.Combine(Bin, @"ue4ss\UE4SS-settings.ini"), @"ue4ss\UE4SS-settings.ini");

            var saved = Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "", @"PenDriverPro\Saved");
            var logs = Path.Combine(saved, "Logs");
            if (Directory.Exists(logs)) foreach (var f in Directory.GetFiles(logs, "*.log").Where(f => File.GetLastWriteTime(f) > week)) take(f, @"engine\" + Path.GetFileName(f));
            var crashes = Path.Combine(saved, "Crashes");
            if (Directory.Exists(crashes))
                foreach (var d in Directory.GetDirectories(crashes).Where(d => Directory.GetLastWriteTime(d) > week))
                    foreach (var f in Directory.GetFiles(d).Where(f => Regex.IsMatch(Path.GetFileName(f), @"(\.txt|\.xml|\.log|\.runtime-xml)$", RegexOptions.IgnoreCase)))
                        take(f, @"crashes\" + Path.GetFileName(d) + @"\" + Path.GetFileName(f));
            var saves = Path.Combine(saved, "SaveGames");
            if (Directory.Exists(saves))
                foreach (var f in Directory.GetFiles(saves, "*.sav").Where(f => !Path.GetFileName(f).Contains("-backup-") || File.GetLastWriteTime(f) > DateTime.Now.AddDays(-2)))
                    take(f, @"saves\" + Path.GetFileName(f));
            var side = Path.Combine(folder.Text.Trim(), @"PenDriverPro\Saved\SaveGames");  // backpack.lua's side files (guest backpacks per host slot)
            if (Directory.Exists(side)) foreach (var f in Directory.GetFiles(side, "*.pt-*.txt")) take(f, @"saves\side\" + Path.GetFileName(f));
            take(Path.Combine(saved, @"Config\Windows\GameUserSettings.ini"), @"saves\GameUserSettings.ini");

            File.WriteAllText(Path.Combine(tmp, "system.txt"), SystemInfo());
            if (n == 0) { Fail("No logs found yet. Start the game once with the mod installed."); return; }
            File.WriteAllText(Path.Combine(tmp, "list.txt"), "Copied " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n" + list);
            var desk = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            var zip = Path.Combine(desk, "PacificTogether-logs-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".zip");
            ZipFile.CreateFromDirectory(tmp, zip, CompressionLevel.Optimal, false);
            Log(string.Format("{0} files saved to {1} ({2:N1} MB)", n, zip, new FileInfo(zip).Length / 1048576.0));
            Process.Start("explorer.exe", "/select,\"" + zip + "\"");
        }
        catch (Exception ex) { Fail("Could not copy logs: " + ex.Message); }
        finally { try { Directory.Delete(tmp, true); } catch { } }
    }

    string SystemInfo()
    {
        var s = new StringBuilder();
        Action<string, string, string> wmi = (label, cls, props) =>
        {
            try
            {
                using (var q = new System.Management.ManagementObjectSearcher("SELECT " + props + " FROM " + cls))
                    foreach (System.Management.ManagementObject o in q.Get())
                        s.AppendLine(label + ": " + string.Join("  ", props.Split(',').Select(p => p.Trim() + "=" + o[p.Trim()])));
            }
            catch (Exception ex) { s.AppendLine(label + ": ? (" + ex.Message + ")"); }
        };
        s.AppendLine("Launcher: " + BundledVersion() + "   installed: " + (Stamp(Bin) ?? "not installed"));
        wmi("OS", "Win32_OperatingSystem", "Caption, Version, OSArchitecture");
        wmi("CPU", "Win32_Processor", "Name, NumberOfCores, NumberOfLogicalProcessors");
        wmi("Memory", "Win32_ComputerSystem", "TotalPhysicalMemory");
        wmi("GPU", "Win32_VideoController", "Name, DriverVersion, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate");
        s.AppendLine("Screens: " + string.Join(", ", Screen.AllScreens.Select(x => x.Bounds.Width + "x" + x.Bounds.Height + (x.Primary ? " primary" : ""))));
        s.AppendLine("Steam: " + (SteamExe() ?? "not found") + "   game running: " + GameRunning());
        var exe = Path.Combine(Bin, "PenDriverPro-Win64-Shipping.exe");
        try
        {
            using (var sha = System.Security.Cryptography.SHA256.Create()) using (var f = File.OpenRead(exe))
            {
                var h = BitConverter.ToString(sha.ComputeHash(f)).Replace("-", "");
                s.AppendLine("Game exe SHA-256: " + h + (h == "568BB63476C6DE5FC2B1878572A655DD631DD25BB44FE304E3D96A51F6B98F7E" ? " (the tested build)" : " (NOT the tested build)"));
            }
        }
        catch (Exception ex) { s.AppendLine("Game exe: ? (" + ex.Message + ")"); }
        s.AppendLine("Game folder: " + folder.Text.Trim());
        return s.ToString();
    }

    // ---- entry ----
    // the release exe carries the package as the resource payload.zip: unpacked once per version (its version.txt names the folder)
    static void Unpack()
    {
        var res = typeof(App).Assembly.GetManifestResourceStream("payload.zip");
        if (res == null) return;  // dev build: the package sits next to the exe
        using (res)
        using (var z = new ZipArchive(res, ZipArchiveMode.Read))
        {
            var stamp = z.Entries.FirstOrDefault(e => e.FullName.Replace('\\', '/') == "game/ue4ss/Mods/PacificTogether/version.txt");
            if (stamp == null) throw new InvalidDataException("payload has no version.txt");
            string ver;
            using (var r = new StreamReader(stamp.Open())) ver = r.ReadToEnd().Trim();
            var dir = Path.Combine(Data, "app", Regex.Replace(ver, @"[^\w.\-]", "_"));
            if (!File.Exists(Path.Combine(dir, @"game\ue4ss\Mods\PacificTogether\version.txt")))
            {
                var part = dir + ".part";
                if (Directory.Exists(part)) Directory.Delete(part, true);
                z.ExtractToDirectory(part);
                if (Directory.Exists(dir)) Directory.Delete(dir, true);
                Directory.Move(part, dir);
            }
            baseDir = dir;
        }
    }

    [STAThread]
    static void Main(string[] a)
    {
        string shot = null; int tab = 0; float scale = 1f; bool doCollect = false;
        for (int i = 0; i < a.Length; i++)
        {
            if (a[i] == "--shot" && i + 1 < a.Length) shot = a[++i];
            else if (a[i] == "--tab" && i + 1 < a.Length) tab = int.Parse(a[++i]);
            else if (a[i] == "--collect") doCollect = true;
            else if (a[i] == "--scale" && i + 1 < a.Length) scale = float.Parse(a[++i], System.Globalization.CultureInfo.InvariantCulture);
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var g = Graphics.FromHwnd(IntPtr.Zero)) UI.Px = g.DpiX / 96f * scale;
        UI.Pt = scale;
        try { Unpack(); }
        catch (Exception ex) { MessageBox.Show("Could not unpack the mod: " + ex.Message, "Pacific Together", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
        var f = new App(tab);
        if (doCollect) f.Shown += delegate { f.collect.PerformClick(); f.Close(); };  // test hook
        if (shot != null)
        {
            f.Shown += delegate
            {
                var t = new System.Windows.Forms.Timer { Interval = 600 };
                t.Tick += delegate
                {
                    t.Stop();
                    using (var bmp = new Bitmap(f.Width, f.Height))
                    {
                        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(f.Left, f.Top, 0, 0, f.Size);
                        bmp.Save(shot, System.Drawing.Imaging.ImageFormat.Png);
                    }
                    f.Close();
                };
                t.Start();
            };
        }
        Application.Run(f);
    }
}
