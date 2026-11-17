using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Net;
using Microsoft.Win32;

namespace PcAudioRelay;

static class Theme
{
    public static readonly Color Bg = Color.FromArgb(243, 244, 247);
    public static readonly Color Card = Color.White;
    public static readonly Color Border = Color.FromArgb(226, 229, 235);
    public static readonly Color Text = Color.FromArgb(28, 30, 36);
    public static readonly Color Sub = Color.FromArgb(108, 114, 126);
    public static readonly Color Accent = Color.FromArgb(37, 105, 235);
    public static readonly Color Green = Color.FromArgb(30, 168, 92);
    public static readonly Color Orange = Color.FromArgb(240, 148, 28);
    public static readonly Color Track = Color.FromArgb(234, 236, 241);
    static string FontName => L.FontName;
    public static Font F(float size, FontStyle st = FontStyle.Regular) => new(FontName, size, st);

    public static GraphicsPath Round(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    public static Icon AppIcon()
    {
        using var s = typeof(Theme).Assembly.GetManifestResourceStream("app.ico");
        return s != null ? new Icon(s) : SystemIcons.Application;
    }
}

/// <summary>状态小圆点</summary>
sealed class Dot : Control
{
    Color _color = Theme.Orange;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Color DotColor { get => _color; set { _color = value; Invalidate(); } }
    public Dot() { DoubleBuffered = true; BackColor = Theme.Card; }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var b = new SolidBrush(_color);
        e.Graphics.FillEllipse(b, 0, 0, Width - 1, Height - 1);
    }
}

/// <summary>音量条</summary>
sealed class LevelMeter : Control
{
    float _value;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public float Value { get => _value; set { _value = Math.Clamp(value, 0, 1); Invalidate(); } }
    public LevelMeter() { DoubleBuffered = true; BackColor = Theme.Card; }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var r = new RectangleF(0, 0, Width - 1, Height - 1);
        using (var track = Theme.Round(r, r.Height / 2))
        using (var tb = new SolidBrush(Theme.Track))
            g.FillPath(tb, track);
        float w = r.Width * _value;
        if (w < r.Height) return;
        var fr = new RectangleF(0, 0, w, r.Height);
        using var fill = Theme.Round(fr, r.Height / 2);
        using var fb = new LinearGradientBrush(new RectangleF(0, 0, r.Width, r.Height), Theme.Green, Color.FromArgb(70, 200, 120), LinearGradientMode.Horizontal);
        g.FillPath(fb, fill);
    }
}

sealed class MainForm : Form
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunValue = "SoundBridge";
    const string SettingsKey = @"Software\SoundBridge";

    readonly RelayServer _server;
    readonly LoopbackSource _source;
    readonly List<IPAddress> _ips;
    bool _allowShow;
    bool _exiting;
    bool _trayTipShown;

    readonly NotifyIcon _tray;
    readonly System.Windows.Forms.Timer _timer;
    int _tick;
    readonly ConcurrentQueue<string> _logQueue = new();
    readonly List<string> _logLines = new();
    LogForm? _logForm;

    readonly List<Control[]> _cards = new();
    readonly float _k;

    // 控件
    readonly Dot _dot = new();
    readonly Label _status = new();
    readonly Label _devices = new();
    readonly LevelMeter _meter = new();
    readonly Label _sourceLabel = new();
    readonly Label _ipLabel = new();
    readonly CheckBox _chkAutoStart = new();
    readonly CheckBox _chkTray = new();
    readonly ComboBox _langBox = new();
    bool _building;

    int S(float v) => (int)Math.Round(v * _k);

    public MainForm(RelayServer server, LoopbackSource source, List<IPAddress> ips, bool startHidden)
    {
        _server = server;
        _source = source;
        _ips = ips;
        _allowShow = !startHidden;
        // 窗口句柄还没建好时 DeviceDpi 会是 96，直接读系统 DPI（进程是 SystemAware）
        using (var sg = Graphics.FromHwnd(IntPtr.Zero)) _k = sg.DpiX / 96f;

        AutoScaleMode = AutoScaleMode.None;
        Icon = Theme.AppIcon();
        BackColor = Theme.Bg;
        ForeColor = Theme.Text;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;

        AppLog.Message += line => _logQueue.Enqueue(line);

        // 复选框和语言框的事件只挂一次（切换语言时界面会重建）
        _chkAutoStart.CheckedChanged += (_, _) => { if (!_building) SetAutoStart(_chkAutoStart.Checked); };
        _chkTray.CheckedChanged += (_, _) => { if (!_building) CloseToTray = _chkTray.Checked; };
        _langBox.DropDownStyle = ComboBoxStyle.DropDownList;
        _langBox.SelectedIndexChanged += (_, _) =>
        {
            if (_building || _langBox.SelectedIndex < 0) return;
            var code = _langBox.SelectedIndex == 0 ? "" : L.Languages[_langBox.SelectedIndex - 1].Code;
            if (code == L.Override) return;
            L.Set(code);
            BeginInvoke(RebuildForLanguage);
        };

        BuildUi();

        _tray = new NotifyIcon
        {
            Icon = Theme.AppIcon(),
            Text = Text,
            Visible = true,
            ContextMenuStrip = BuildTrayMenu(),
        };
        _tray.DoubleClick += (_, _) => ShowFromTray();

        _timer = new System.Windows.Forms.Timer { Interval = 50 };
        _timer.Tick += (_, _) => OnTick();
        _timer.Start();
        RefreshStatus();
    }

    // ───────────────────────── 界面 ─────────────────────────

    /// <summary>切换语言后整个界面按新语言重建</summary>
    void RebuildForLanguage()
    {
        SuspendLayout();
        var old = Controls.Cast<Control>().ToList();
        Controls.Clear();
        foreach (var c in old)
            if (c != _dot && c != _status && c != _devices && c != _meter && c != _sourceLabel && c != _ipLabel &&
                c != _chkAutoStart && c != _chkTray && c != _langBox) c.Dispose();
        _cards.Clear();
        BuildUi();
        _tray.ContextMenuStrip?.Dispose();
        _tray.ContextMenuStrip = BuildTrayMenu();
        if (_logForm != null && !_logForm.IsDisposed) _logForm.Text = L.T("声桥 - 日志", "SoundBridge - Log");
        ResumeLayout();
        RefreshStatus();
        Invalidate();
    }

    void BuildUi()
    {
        _building = true;
        Text = L.T("声桥", "SoundBridge");
        Font = Theme.F(9.75f);
        int W = S(440);
        int left = S(36);
        int inner = S(368);
        int y = S(18);

        var title = new Label { Text = L.T("声桥", "SoundBridge"), Font = Theme.F(17, FontStyle.Bold), AutoSize = true, BackColor = Theme.Bg };
        Add(title, S(20), ref y, S(2));
        var subtitle = new Label
        {
            Text = L.T("把电脑的声音传到 iPhone，再送进你的助听器或耳机", "Send your PC's sound to your iPhone — and on to your hearing aids or headphones"),
            ForeColor = Theme.Sub, AutoSize = true, MaximumSize = new Size(S(400), 0), BackColor = Theme.Bg,
        };
        Add(subtitle, S(20), ref y, S(22));

        // 卡片 1：状态
        y += S(16);
        var c1 = new List<Control>();
        _dot.Size = new Size(S(12), S(12));
        _status.Font = Theme.F(12.5f, FontStyle.Bold);
        _status.AutoSize = true;
        _status.BackColor = Theme.Card;
        _status.Location = new Point(left + S(20), y);
        Controls.Add(_status);
        _dot.Location = new Point(left, y + (_status.PreferredHeight - _dot.Height) / 2 + S(1));
        Controls.Add(_dot);
        c1.Add(_status); c1.Add(_dot);
        y += _status.PreferredHeight + S(6);

        _devices.AutoSize = false;
        _devices.Size = new Size(inner, S(40));
        _devices.ForeColor = Theme.Sub;
        _devices.BackColor = Theme.Card;
        Add(_devices, left, ref y, S(10), c1);

        var meterCap = new Label { Text = L.T("电脑正在放的声音", "What your PC is playing"), Font = Theme.F(9), ForeColor = Theme.Sub, AutoSize = true, BackColor = Theme.Card };
        Add(meterCap, left, ref y, S(6), c1);
        _meter.Size = new Size(inner, S(10));
        Add(_meter, left, ref y, S(8), c1);
        _sourceLabel.AutoSize = false;
        _sourceLabel.AutoEllipsis = true;
        _sourceLabel.Size = new Size(inner, S(20));
        _sourceLabel.Font = Theme.F(8.5f);
        _sourceLabel.ForeColor = Theme.Sub;
        _sourceLabel.BackColor = Theme.Card;
        Add(_sourceLabel, left, ref y, 0, c1);
        _cards.Add(c1.ToArray());

        // 卡片 2：使用方法
        y += S(44);
        var c2 = new List<Control>();
        Add(new Label { Text = L.T("使用方法", "How to use"), Font = Theme.F(10.5f, FontStyle.Bold), AutoSize = true, BackColor = Theme.Card }, left, ref y, S(10), c2);
        string[] steps =
        {
            L.T("1.  手机和这台电脑连同一个 Wi-Fi", "1.  Connect your iPhone and this PC to the same Wi-Fi"),
            L.T("2.  在 iPhone 上打开「声桥」App，点中间的大按钮", "2.  Open the SoundBridge app on your iPhone and tap the big button"),
            L.T("3.  电脑上放的声音，就会从手机连着的助听器或耳机里出来", "3.  Sound from this PC now plays through whatever your iPhone is using — hearing aids or headphones"),
        };
        foreach (var s in steps)
            Add(new Label { Text = s, AutoSize = true, MaximumSize = new Size(inner, 0), BackColor = Theme.Card }, left, ref y, S(8), c2);
        y += S(6);
        Add(new Label { Text = L.T("App 里找不到这台电脑？手动填这个地址：", "App can't find this PC? Enter this address:"), ForeColor = Theme.Sub, AutoSize = true, MaximumSize = new Size(inner, 0), BackColor = Theme.Card }, left, ref y, S(4), c2);

        _ipLabel.Font = Theme.F(13, FontStyle.Bold);
        _ipLabel.ForeColor = Theme.Accent;
        _ipLabel.AutoSize = true;
        _ipLabel.BackColor = Theme.Card;
        _ipLabel.Text = _ips.Count > 0 ? string.Join("  /  ", _ips) : L.T("（没有检测到局域网）", "(no local network found)");
        _ipLabel.Location = new Point(left, y);
        Controls.Add(_ipLabel);
        c2.Add(_ipLabel);
        if (_ips.Count > 0)
        {
            var copy = new LinkLabel { Text = L.T("复制", "Copy"), AutoSize = true, BackColor = Theme.Card, LinkColor = Theme.Accent, ActiveLinkColor = Theme.Accent };
            copy.Location = new Point(left + _ipLabel.PreferredWidth + S(10), y + (_ipLabel.PreferredHeight - copy.PreferredHeight) / 2);
            copy.LinkClicked += (_, _) =>
            {
                try { Clipboard.SetText(_ips[0].ToString()); copy.Text = L.T("已复制", "Copied"); } catch { }
            };
            Controls.Add(copy);
            c2.Add(copy);
        }
        y += _ipLabel.PreferredHeight + S(4);
        Add(new Label { Text = L.T("这台电脑在 App 里显示为：{0}", "Shown in the app as: {0}", Environment.MachineName), Font = Theme.F(9), ForeColor = Theme.Sub, AutoSize = true, BackColor = Theme.Card }, left, ref y, 0, c2);
        _cards.Add(c2.ToArray());

        // 卡片 3：设置
        y += S(44);
        var c3 = new List<Control>();
        _chkAutoStart.Text = L.T("开机自动启动（在后台运行，不弹窗口）", "Start with Windows (runs in the background)");
        _chkAutoStart.AutoSize = true;
        _chkAutoStart.BackColor = Theme.Card;
        _chkAutoStart.Checked = IsAutoStart();
        Add(_chkAutoStart, left, ref y, S(6), c3);

        _chkTray.Text = L.T("点关闭时缩到右下角，继续传声", "Keep running in the tray when closed");
        _chkTray.AutoSize = true;
        _chkTray.BackColor = Theme.Card;
        _chkTray.Checked = CloseToTray;
        Add(_chkTray, left, ref y, S(10), c3);

        // 语言：第一项是「跟随系统」，后面是各语言的本地名称
        var langLabel = new Label { Text = "🌐  " + L.T("语言", "Language"), AutoSize = true, BackColor = Theme.Card };
        _langBox.Font = Theme.F(9.75f);
        _langBox.Items.Clear();
        _langBox.Items.Add(L.T("跟随系统", "System default"));
        foreach (var lang in L.Languages) _langBox.Items.Add(lang.Name);
        int idx = L.Languages.FindIndex(l => l.Code == L.Override);
        _langBox.SelectedIndex = idx < 0 ? 0 : idx + 1;
        _langBox.Width = S(170);
        _langBox.Location = new Point(left + inner - _langBox.Width, y);
        langLabel.Location = new Point(left, y + (_langBox.PreferredHeight - langLabel.PreferredHeight) / 2);
        Controls.Add(langLabel); c3.Add(langLabel);
        Controls.Add(_langBox); c3.Add(_langBox);
        y += _langBox.PreferredHeight + S(12);

        var help = new LinkLabel { Text = L.T("下载 iPhone App / 使用说明", "Get the iPhone app / Help"), AutoSize = true, BackColor = Theme.Card, LinkColor = Theme.Accent, ActiveLinkColor = Theme.Accent };
        help.LinkClicked += (_, _) => OpenUrl(AppInfo.ProjectUrl);
        help.Location = new Point(left, y);
        Controls.Add(help); c3.Add(help);
        var log = new LinkLabel { Text = L.T("查看日志", "Log"), AutoSize = true, BackColor = Theme.Card, LinkColor = Theme.Sub, ActiveLinkColor = Theme.Sub };
        log.LinkClicked += (_, _) => ShowLog();
        log.Location = new Point(help.Right + S(16), y);
        Controls.Add(log); c3.Add(log);
        var ver = new Label { Text = "v" + AppInfo.Version, AutoSize = true, ForeColor = Theme.Sub, BackColor = Theme.Card, Font = Theme.F(8.5f) };
        ver.Location = new Point(left + inner - ver.PreferredWidth, y + S(2));
        Controls.Add(ver); c3.Add(ver);
        y += help.PreferredHeight;
        _cards.Add(c3.ToArray());

        y += S(16) + S(20);
        ClientSize = new Size(W, y);
        _building = false;
    }

    void Add(Control c, int x, ref int y, int gapAfter, List<Control>? card = null)
    {
        c.Location = new Point(x, y);
        Controls.Add(c);
        card?.Add(c);
        int h = c is Label lb && lb.AutoSize ? lb.PreferredHeight : c.Height;
        if (c is Label l2 && l2.AutoSize && l2.MaximumSize.Width > 0)
            h = l2.GetPreferredSize(new Size(l2.MaximumSize.Width, 0)).Height;
        if (c is CheckBox cb && cb.AutoSize) h = cb.PreferredSize.Height;
        y += h + gapAfter;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int left = S(20), width = S(400), pad = S(16);
        foreach (var card in _cards)
        {
            int top = card.Min(c => c.Top) - pad;
            int bottom = card.Max(c => c.Bottom) + pad;
            var r = new RectangleF(left, top, width, bottom - top);
            using var path = Theme.Round(r, S(12));
            using var fill = new SolidBrush(Theme.Card);
            using var pen = new Pen(Theme.Border, 1);
            g.FillPath(fill, path);
            g.DrawPath(pen, path);
        }
    }

    ContextMenuStrip BuildTrayMenu()
    {
        var m = new ContextMenuStrip();
        m.Items.Add(L.T("打开窗口", "Open"), null, (_, _) => ShowFromTray());
        m.Items.Add(L.T("查看日志", "Log"), null, (_, _) => { ShowFromTray(); ShowLog(); });
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add(L.T("退出（停止传声）", "Quit (stop streaming)"), null, (_, _) => ExitApp());
        return m;
    }

    // ───────────────────────── 状态刷新 ─────────────────────────

    void OnTick()
    {
        // 音量条：峰值换算成分贝刻度，快升慢降
        float peak = _source.TakePeak();
        float target = peak <= 0.0001f ? 0 : Math.Clamp((20f * MathF.Log10(peak) + 50f) / 50f, 0, 1);
        float v = Math.Max(target, _meter.Value * 0.88f);
        if (Visible && Math.Abs(v - _meter.Value) > 0.002f) _meter.Value = v;

        if (++_tick % 10 == 0) RefreshStatus();

        bool newLines = false;
        while (_logQueue.TryDequeue(out var line))
        {
            _logLines.Add(line);
            newLines = true;
        }
        if (_logLines.Count > 400) _logLines.RemoveRange(0, _logLines.Count - 400);
        if (newLines) _logForm?.SetLines(_logLines);
    }

    void RefreshStatus()
    {
        var clients = _server.Snapshot();
        if (clients.Count == 0)
        {
            _dot.DotColor = Theme.Orange;
            _status.Text = L.T("等待 iPhone 连接", "Waiting for iPhone");
            _devices.Text = L.T("在 iPhone 上打开「声桥」App，就会自动连上。", "Open the SoundBridge app on your iPhone — it connects automatically.");
        }
        else
        {
            _dot.DotColor = Theme.Green;
            _status.Text = clients.Count == 1
                ? L.T("正在传给 iPhone", "Streaming to iPhone")
                : L.T("正在传给 {0} 台设备", "Streaming to {0} devices", clients.Count);
            _devices.Text = string.Join("\n", clients.Take(2).Select(c =>
                $"{(string.IsNullOrEmpty(c.Device) ? "iPhone" : c.Device)}  ·  {c.Address}"));
        }
        var dev = _source.DeviceName;
        _sourceLabel.Text = string.IsNullOrEmpty(dev)
            ? L.T("没有找到播放设备", "No playback device found")
            : L.T("声音来源：{0}", "Source: {0}", dev);
        var tip = clients.Count == 0 ? _status.Text : $"{Text} — {_status.Text}";
        _tray.Text = tip.Length > 63 ? tip[..63] : tip;
        Invalidate(); // 卡片高度不变，这里只为重画小圆点附近
    }

    // ───────────────────────── 窗口 / 托盘 ─────────────────────────

    protected override void SetVisibleCore(bool value)
    {
        if (!_allowShow)
        {
            value = false;
            if (!IsHandleCreated) CreateHandle();
        }
        base.SetVisibleCore(value);
    }

    public void ShowFromTray()
    {
        _allowShow = true;
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
        BringToFront();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_exiting && e.CloseReason == CloseReason.UserClosing && CloseToTray)
        {
            e.Cancel = true;
            Hide();
            if (!_trayTipShown)
            {
                _trayTipShown = true;
                _tray.ShowBalloonTip(4000, Text,
                    L.T("声桥还在后台继续传声。双击右下角的图标可以重新打开，右键可以退出。",
                        "Still streaming in the background. Double-click the tray icon to open, right-click to quit."),
                    ToolTipIcon.Info);
            }
            return;
        }
        _timer.Stop();
        _tray.Visible = false;
        _tray.Dispose();
        base.OnFormClosing(e);
    }

    void ExitApp()
    {
        _exiting = true;
        _allowShow = true;
        Close();
    }

    void ShowLog()
    {
        if (_logForm == null || _logForm.IsDisposed)
        {
            _logForm = new LogForm(_k);
            _logForm.SetLines(_logLines);
        }
        _logForm.Show(this);
        _logForm.Activate();
    }

    static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    // ───────────────────────── 设置 ─────────────────────────

    static bool IsAutoStart()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey);
        return k?.GetValue(RunValue) is string;
    }

    static void SetAutoStart(bool on)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) k.SetValue(RunValue, $"\"{Environment.ProcessPath}\" --minimized");
            else k.DeleteValue(RunValue, false);
        }
        catch (Exception e)
        {
            AppLog.Write(L.T($"设置开机启动失败：{e.Message}", $"Couldn't change startup setting: {e.Message}"));
        }
    }

    static bool CloseToTray
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(SettingsKey);
            return (k?.GetValue("CloseToTray") as int? ?? 1) != 0;
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(SettingsKey);
            k.SetValue("CloseToTray", value ? 1 : 0, RegistryValueKind.DWord);
        }
    }
}

/// <summary>日志窗口：出问题时给别人看</summary>
sealed class LogForm : Form
{
    readonly TextBox _box = new();

    public LogForm(float k)
    {
        Text = L.T("声桥 - 日志", "SoundBridge - Log");
        Icon = Theme.AppIcon();
        AutoScaleMode = AutoScaleMode.None;
        ClientSize = new Size((int)(560 * k), (int)(360 * k));
        StartPosition = FormStartPosition.CenterParent;
        _box.Multiline = true;
        _box.ReadOnly = true;
        _box.ScrollBars = ScrollBars.Vertical;
        _box.Dock = DockStyle.Fill;
        _box.Font = new Font("Consolas", 9.5f);
        _box.BackColor = Color.White;
        Controls.Add(_box);
    }

    public void SetLines(List<string> lines)
    {
        _box.Text = string.Join(Environment.NewLine, lines);
        _box.SelectionStart = _box.TextLength;
        _box.ScrollToCaret();
    }
}
