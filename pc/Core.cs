using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Dsp;
using NAudio.Wave;

namespace PcAudioRelay;

/// <summary>全局日志和状态，界面订阅这些事件。</summary>
static class AppLog
{
    public static event Action<string>? Message;
    public static void Write(string msg)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] {msg}";
        Debug.WriteLine(line);
        Message?.Invoke(line);
    }
}

/// <summary>按系统语言选中文或英文</summary>
/// <summary>
/// 多语言：简体中文和英文写在代码里 T("中文", "English")，其他语言按英文原文去 i18n/strings.json 里查，查不到退回英文。
/// 语言默认跟系统，用户可以在窗口里手动选（存在注册表）。
/// </summary>
static class L
{
    const string Key = @"Software\SoundBridge";

    public sealed record Lang(string Code, string Name);

    static readonly Dictionary<string, Dictionary<string, string>> Table = new();
    public static readonly List<Lang> Languages = new();

    /// <summary>当前语言代码：en / zh-Hans / zh-Hant / ja / ko / es / fr / de / pt / ru</summary>
    public static string Code { get; private set; } = "en";
    /// <summary>用户手动选的语言；空 = 跟系统</summary>
    public static string Override { get; private set; } = "";

    public static bool Zh => Code is "zh-Hans" or "zh-Hant";

    static L()
    {
        try
        {
            using var s = typeof(L).Assembly.GetManifestResourceStream("strings.json");
            if (s != null)
            {
                using var doc = System.Text.Json.JsonDocument.Parse(s);
                foreach (var l in doc.RootElement.GetProperty("languages").EnumerateArray())
                    Languages.Add(new Lang(l.GetProperty("code").GetString()!, l.GetProperty("name").GetString()!));
                foreach (var p in doc.RootElement.GetProperty("strings").EnumerateObject())
                {
                    var d = new Dictionary<string, string>();
                    foreach (var t in p.Value.EnumerateObject()) d[t.Name] = t.Value.GetString() ?? "";
                    Table[p.Name] = d;
                }
            }
        }
        catch { }
        if (Languages.Count == 0) { Languages.Add(new Lang("en", "English")); Languages.Add(new Lang("zh-Hans", "简体中文")); }
        try
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Key);
            Override = k?.GetValue("Language") as string ?? "";
        }
        catch { }
        Code = Resolve(Override);
    }

    /// <summary>按系统 UI 语言推断</summary>
    static string Detect()
    {
        var ci = System.Globalization.CultureInfo.CurrentUICulture;
        var name = ci.Name.ToLowerInvariant();
        if (name.StartsWith("zh"))
            return name.Contains("hant") || name.EndsWith("-tw") || name.EndsWith("-hk") || name.EndsWith("-mo") ? "zh-Hant" : "zh-Hans";
        var two = ci.TwoLetterISOLanguageName;
        return Languages.Any(l => l.Code == two) ? two : "en";
    }

    static string Resolve(string over) => Languages.Any(l => l.Code == over) ? over : Detect();

    /// <summary>手动选语言；传空字符串 = 跟系统</summary>
    public static void Set(string code)
    {
        Override = code;
        Code = Resolve(code);
        try
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Key);
            k.SetValue("Language", code);
        }
        catch { }
    }

    public static string T(string zh, string en, params object[] args)
    {
        string s;
        if (Code == "zh-Hans") s = zh;
        else if (Code == "en") s = en;
        else s = Table.TryGetValue(en, out var d) && d.TryGetValue(Code, out var v) && v.Length > 0 ? v : en;
        if (args.Length > 0)
        {
            try { s = string.Format(System.Globalization.CultureInfo.InvariantCulture, s, args); } catch { }
        }
        return s;
    }

    /// <summary>每种语言用合适的系统字体</summary>
    public static string FontName => Code switch
    {
        "zh-Hans" => "Microsoft YaHei UI",
        "zh-Hant" => "Microsoft JhengHei UI",
        "ja" => "Yu Gothic UI",
        "ko" => "Malgun Gothic",
        _ => "Segoe UI",
    };
}

static class AppInfo
{
    public const int DefaultPort = 47800;
    public const string ServiceType = "_hearrelay._tcp";
    public const string Version = "1.3.2";
    public const string ProjectUrl = "https://github.com/Mirazia/SoundBridge";
}

/// <summary>
/// 抓默认播放设备的声音（WASAPI loopback），转成 float 立体声交给服务端。默认设备切换时自动跟随。
/// 电脑没在出声时 loopback 不给数据，这里用定时器补静音，让手机端的数据流保持均匀，不会误判成网络卡顿。
/// </summary>
sealed class LoopbackSource : IMMNotificationClient, IDisposable
{
    readonly RelayServer _server;
    readonly MMDeviceEnumerator _enumerator = new();
    readonly object _gate = new();
    readonly object _emitGate = new();
    WasapiLoopbackCapture? _capture;
    WaveFormat? _format;
    bool _disposed;
    CancellationTokenSource? _restartDebounce;
    readonly Stopwatch _clock = Stopwatch.StartNew();
    long _lastEmitTicks;
    long _lastRealTicks;
    readonly System.Threading.Timer _silenceTimer;
    volatile float _peak;

    /// <summary>正在抓取的播放设备名</summary>
    public string DeviceName { get; private set; } = "";
    public event Action? DeviceChanged;

    /// <summary>读出自上次读取以来的峰值（0~1），给界面音量条用</summary>
    public float TakePeak() { var p = _peak; _peak = 0; return p; }

    public LoopbackSource(RelayServer server)
    {
        _server = server;
        _enumerator.RegisterEndpointNotificationCallback(this);
        _silenceTimer = new System.Threading.Timer(_ => FillSilence(), null, 20, 10);
    }

    public void Start()
    {
        lock (_gate)
        {
            if (_disposed) return;
            StopCaptureLocked();
            try
            {
                var dev = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                var cap = new WasapiLoopbackCapture(dev);
                _format = cap.WaveFormat;
                cap.DataAvailable += OnData;
                cap.RecordingStopped += (_, e) =>
                {
                    if (e.Exception != null && !_disposed)
                    {
                        AppLog.Write(L.T($"抓声中断：{e.Exception.Message}，1 秒后重试。", $"Capture stopped: {e.Exception.Message}. Retrying in 1 s."));
                        ScheduleRestart(1000);
                    }
                };
                _capture = cap;
                _server.SetSourceRate(_format.SampleRate);
                cap.StartRecording();
                DeviceName = dev.FriendlyName;
                AppLog.Write(L.T($"正在传送这个设备的声音：{dev.FriendlyName}（{_format.SampleRate} Hz）",
                                 $"Capturing: {dev.FriendlyName} ({_format.SampleRate} Hz)"));
            }
            catch (Exception ex)
            {
                DeviceName = "";
                AppLog.Write(L.T($"打开播放设备失败：{ex.Message}，3 秒后重试。", $"Can't open playback device: {ex.Message}. Retrying in 3 s."));
                ScheduleRestart(3000);
            }
            DeviceChanged?.Invoke();
        }
    }

    void StopCaptureLocked()
    {
        if (_capture == null) return;
        _capture.DataAvailable -= OnData;
        try { _capture.StopRecording(); } catch { }
        _capture.Dispose();
        _capture = null;
    }

    void ScheduleRestart(int delayMs)
    {
        _restartDebounce?.Cancel();
        var cts = new CancellationTokenSource();
        _restartDebounce = cts;
        Task.Delay(delayMs, cts.Token).ContinueWith(t => { if (!t.IsCanceled) Start(); }, TaskScheduler.Default);
    }

    void OnData(object? sender, WaveInEventArgs e)
    {
        var fmt = _format;
        if (fmt == null || e.BytesRecorded == 0) return;
        lock (_emitGate)
        {
            _lastEmitTicks = _lastRealTicks = _clock.ElapsedTicks;
            var (st, frames) = ToStereoFloat(e.Buffer, e.BytesRecorded, fmt);
            float peak = _peak;
            for (int i = 0; i < frames * 2; i++) { float a = Math.Abs(st[i]); if (a > peak) peak = a; }
            _peak = peak;
            if (frames > 0 && _server.HasClients) _server.Broadcast(st, frames, fmt.SampleRate);
        }
    }

    /// <summary>真实数据断了 200ms 以上（电脑确实没在出声）才补静音，按流逝时间补（单次最多 100ms）。
    /// 有声音时 loopback 本身就可能一阵一阵地给数据（虚拟声卡尤其明显），这些空隙不能补，否则数据会比实际时间多。</summary>
    void FillSilence()
    {
        var fmt = _format;
        if (fmt == null || _disposed) return;
        lock (_emitGate)
        {
            long now = _clock.ElapsedTicks;
            double silentMs = (now - _lastRealTicks) * 1000.0 / Stopwatch.Frequency;
            if (silentMs < 200) return;
            double gapMs = (now - _lastEmitTicks) * 1000.0 / Stopwatch.Frequency;
            if (gapMs < 10) return;
            _lastEmitTicks = now;
            if (!_server.HasClients) return;
            int frames = (int)(Math.Min(gapMs, 100) / 1000.0 * fmt.SampleRate);
            if (frames > 0) _server.Broadcast(new float[frames * 2], frames, fmt.SampleRate);
        }
    }

    static bool IsFloat(WaveFormat f)
    {
        if (f.Encoding == WaveFormatEncoding.IeeeFloat) return true;
        if (f is WaveFormatExtensible ext) return ext.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
        return false;
    }

    static (float[] data, int frames) ToStereoFloat(byte[] buf, int count, WaveFormat f)
    {
        int ch = f.Channels;
        int bps = f.BitsPerSample / 8;
        int frameBytes = ch * bps;
        int frames = count / frameBytes;
        var outBuf = new float[frames * 2];
        bool isFloat = IsFloat(f);
        var span = buf.AsSpan(0, frames * frameBytes);
        for (int i = 0; i < frames; i++)
        {
            int baseOff = i * frameBytes;
            float l = Sample(span, baseOff, bps, isFloat);
            float r = ch > 1 ? Sample(span, baseOff + bps, bps, isFloat) : l;
            outBuf[2 * i] = l;
            outBuf[2 * i + 1] = r;
        }
        return (outBuf, frames);
    }

    static float Sample(ReadOnlySpan<byte> s, int off, int bps, bool isFloat)
    {
        if (isFloat && bps == 4) return BitConverter.ToSingle(s.Slice(off, 4));
        return bps switch
        {
            2 => BitConverter.ToInt16(s.Slice(off, 2)) / 32768f,
            3 => ((s[off] | (s[off + 1] << 8) | (s[off + 2] << 16)) << 8 >> 8) / 8388608f,
            4 => BitConverter.ToInt32(s.Slice(off, 4)) / 2147483648f,
            _ => 0f,
        };
    }

    // IMMNotificationClient
    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
    {
        if (flow == DataFlow.Render && role == Role.Multimedia)
        {
            AppLog.Write(L.T("默认播放设备变了，自动切换……", "Default playback device changed; switching..."));
            ScheduleRestart(500);
        }
    }
    public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
    public void OnDeviceAdded(string pwstrDeviceId) { }
    public void OnDeviceRemoved(string deviceId) { }
    public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }

    public void Dispose()
    {
        _silenceTimer.Dispose();
        lock (_gate)
        {
            _disposed = true;
            _restartDebounce?.Cancel();
            StopCaptureLocked();
        }
        try { _enumerator.UnregisterEndpointNotificationCallback(this); } catch { }
        _enumerator.Dispose();
    }
}

/// <summary>每个客户端自己的重采样器：float 立体声 (源采样率) → 16 位立体声 (客户端要的采样率)。</summary>
sealed class ClientConverter
{
    public int OutRate { get; }
    WdlResampler? _rs;
    int _inRate;

    public ClientConverter(int outRate) { OutRate = outRate; }

    public byte[] Convert(float[] st, int frames, int inRate)
    {
        float[] src = st;
        int outFrames = frames;
        if (inRate != OutRate)
        {
            if (_rs == null || _inRate != inRate)
            {
                _rs = new WdlResampler();
                _rs.SetMode(true, 2, false);
                _rs.SetFilterParms();
                _rs.SetFeedMode(true); // 按输入驱动
                _rs.SetRates(inRate, OutRate);
                _inRate = inRate;
            }
            int need = _rs.ResamplePrepare(frames, 2, out float[] inBuf, out int inOff);
            need = Math.Min(need, frames);
            Array.Copy(st, 0, inBuf, inOff, need * 2);
            int maxOut = (int)((long)frames * OutRate / inRate) + 64;
            src = new float[maxOut * 2];
            outFrames = _rs.ResampleOut(src, 0, need, maxOut, 2);
        }
        var bytes = new byte[outFrames * 4];
        for (int i = 0; i < outFrames * 2; i++)
        {
            float v = src[i];
            if (float.IsNaN(v)) v = 0;
            short s = (short)Math.Round(Math.Clamp(v, -1f, 1f) * 32767f);
            bytes[2 * i] = (byte)s;
            bytes[2 * i + 1] = (byte)(s >> 8);
        }
        return bytes;
    }
}

/// <summary>TCP 服务端：每个客户端一个有界队列，慢客户端丢旧数据，不拖累抓声线程。</summary>
sealed class RelayServer
{
    sealed class Client
    {
        public required TcpClient Tcp;
        public required string Name;
        public readonly Channel<byte[]> Queue = Channel.CreateBounded<byte[]>(
            new BoundedChannelOptions(50) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
        public readonly CancellationTokenSource Cts = new();
        public ClientConverter? Converter;   // Ready 之后才非空
        public bool Legacy;                  // 老版本手机端：跟随源采样率，源采样率变了就断开
        public string Device = "";           // 手机报上来的设备名（1.3+）
    }

    public sealed record ClientInfo(string Device, string Address, int Rate);

    TcpListener? _listener;
    readonly List<Client> _clients = new();
    readonly object _gate = new();
    int _sourceRate = 48000;

    public bool HasClients { get { lock (_gate) return _clients.Count > 0; } }

    /// <summary>连接的手机有变化（连上 / 断开 / 报上设备名）</summary>
    public event Action? ClientsChanged;

    public List<ClientInfo> Snapshot()
    {
        lock (_gate)
            return _clients.Where(c => c.Converter != null)
                .Select(c => new ClientInfo(c.Device, c.Name, c.Converter!.OutRate)).ToList();
    }

    public void Start(int port)
    {
        _listener = new TcpListener(IPAddress.Any, port);
        _listener.Start();
        _ = AcceptLoop();
    }

    public void Stop()
    {
        try { _listener?.Stop(); } catch { }
        List<Client> copy;
        lock (_gate) copy = _clients.ToList();
        foreach (var c in copy) c.Cts.Cancel();
    }

    public void SetSourceRate(int sr)
    {
        List<Client> legacy;
        lock (_gate)
        {
            if (sr == _sourceRate) return;
            _sourceRate = sr;
            legacy = _clients.Where(c => c.Legacy).ToList();
        }
        foreach (var c in legacy) c.Cts.Cancel();
        if (legacy.Count > 0) AppLog.Write(L.T("采样率变化，让老版本手机重连。", "Sample rate changed; asking old clients to reconnect."));
    }

    public void Broadcast(float[] st, int frames, int inRate)
    {
        lock (_gate)
        {
            foreach (var c in _clients)
            {
                var conv = c.Converter;
                if (conv == null) continue;
                c.Queue.Writer.TryWrite(conv.Convert(st, frames, inRate));
            }
        }
    }

    async Task AcceptLoop()
    {
        while (true)
        {
            TcpClient tcp;
            try { tcp = await _listener!.AcceptTcpClientAsync(); }
            catch { return; }
            tcp.NoDelay = true;
            tcp.SendBufferSize = 32 * 1024;
            var ep = tcp.Client.RemoteEndPoint as IPEndPoint;
            var addr = ep == null ? "?" : (ep.Address.IsIPv4MappedToIPv6 ? ep.Address.MapToIPv4() : ep.Address).ToString();
            var client = new Client { Tcp = tcp, Name = addr };
            lock (_gate) _clients.Add(client);
            _ = Serve(client);
        }
    }

    static async Task<int> ReadExactly(NetworkStream s, byte[] buf, int count, CancellationToken ct)
    {
        int n = 0;
        while (n < count)
        {
            int r = await s.ReadAsync(buf.AsMemory(n, count - n), ct);
            if (r == 0) break;
            n += r;
        }
        return n;
    }

    async Task Serve(Client c)
    {
        try
        {
            var stream = c.Tcp.GetStream();

            // 等手机说想要多少采样率（新版手机端会发；老版本不发，超时后按原始采样率）
            int wantRate = 0;
            var req = new byte[10];
            int got = -1; // -1 = 超时没发请求（老版本手机端）
            using (var hello = CancellationTokenSource.CreateLinkedTokenSource(c.Cts.Token))
            {
                hello.CancelAfter(600);
                try
                {
                    got = await ReadExactly(stream, req, 10, hello.Token);
                    if (got == 10 && req[0] == 'H' && req[1] == 'R' && req[2] == 'Q' && req[3] == '1')
                        wantRate = (int)BitConverter.ToUInt32(req, 4);
                }
                catch (OperationCanceledException) when (!c.Cts.IsCancellationRequested) { }
            }
            if (c.Cts.IsCancellationRequested) return;
            // 对方连上就立刻关了 = 手机在扫描局域网找电脑，不算真正连接，安静地结束
            if (got >= 0 && got < 10) return;

            int rate;
            lock (_gate)
            {
                if (wantRate >= 8000 && wantRate <= 96000) { rate = wantRate; c.Legacy = false; }
                else { rate = _sourceRate; c.Legacy = true; }
            }
            AppLog.Write(L.T($"手机已连接：{c.Name}（{rate} Hz{(c.Legacy ? "，旧版手机端" : "")}）",
                             $"Phone connected: {c.Name} ({rate} Hz{(c.Legacy ? ", old app" : "")})"));

            var header = new byte[12];
            "HRLY"u8.CopyTo(header);
            BitConverter.TryWriteBytes(header.AsSpan(4), (uint)rate);
            BitConverter.TryWriteBytes(header.AsSpan(8), (ushort)2);
            BitConverter.TryWriteBytes(header.AsSpan(10), (ushort)16);
            await stream.WriteAsync(header, c.Cts.Token);
            lock (_gate) c.Converter = new ClientConverter(rate);
            ClientsChanged?.Invoke();

            // 读端：手机之后可能发 "HRN1" + u8 长度 + UTF-8 设备名；其余数据忽略。读到 0 表示断开
            _ = Task.Run(async () =>
            {
                var tmp = new byte[512];
                var head = new List<byte>();
                bool parsed = false;
                try
                {
                    int r;
                    while ((r = await stream.ReadAsync(tmp, c.Cts.Token)) > 0)
                    {
                        if (parsed) continue;
                        head.AddRange(tmp.AsSpan(0, r).ToArray());
                        if (head.Count < 5) continue;
                        if (head[0] != 'H' || head[1] != 'R' || head[2] != 'N' || head[3] != '1') { parsed = true; continue; }
                        int len = head[4];
                        if (head.Count < 5 + len) continue;
                        parsed = true;
                        c.Device = System.Text.Encoding.UTF8.GetString(head.GetRange(5, len).ToArray());
                        ClientsChanged?.Invoke();
                    }
                }
                catch { }
                c.Cts.Cancel();
            });
            await foreach (var chunk in c.Queue.Reader.ReadAllAsync(c.Cts.Token))
                await stream.WriteAsync(chunk, c.Cts.Token);
        }
        catch { }
        finally
        {
            bool wasReady;
            lock (_gate) { wasReady = c.Converter != null; _clients.Remove(c); }
            try { c.Tcp.Close(); } catch { }
            if (wasReady)
            {
                AppLog.Write(L.T($"手机已断开：{c.Name}", $"Phone disconnected: {c.Name}"));
                ClientsChanged?.Invoke();
            }
        }
    }
}

/// <summary>用 Windows 自带的 DNS-SD API 广播 _hearrelay._tcp，iPhone 端能自动发现。失败不影响手动填 IP。</summary>
static class Bonjour
{
    [StructLayout(LayoutKind.Sequential)]
    struct DNS_SERVICE_REGISTER_REQUEST
    {
        public uint Version;
        public IntPtr pServiceInstance;
        public IntPtr pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        public IntPtr hCredentials;
        public int unicastEnabled;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void RegisterComplete(uint status, IntPtr queryContext, IntPtr instance);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr DnsServiceConstructInstance(string pServiceName, string pHostName, IntPtr pIp4, IntPtr pIp6,
        ushort wPort, ushort wPriority, ushort wWeight, uint dwPropertiesCount, IntPtr keys, IntPtr values);

    [DllImport("dnsapi.dll")]
    static extern uint DnsServiceRegister(ref DNS_SERVICE_REGISTER_REQUEST request, IntPtr pCancel);

    [DllImport("dnsapi.dll")]
    static extern uint DnsServiceDeRegister(ref DNS_SERVICE_REGISTER_REQUEST request, IntPtr pCancel);

    static RegisterComplete? _callback;
    static DNS_SERVICE_REGISTER_REQUEST _req;
    static IntPtr _ip4;
    static bool _registered;

    public static void Register(string machine, int port, IPAddress? ip)
    {
        try
        {
            var host = machine + ".local";
            var instanceName = $"{machine}.{AppInfo.ServiceType}.local";
            if (ip != null)
            {
                _ip4 = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(_ip4, BitConverter.ToInt32(ip.GetAddressBytes(), 0));
            }
            var inst = DnsServiceConstructInstance(instanceName, host, _ip4, IntPtr.Zero, (ushort)port, 0, 0, 0, IntPtr.Zero, IntPtr.Zero);
            if (inst == IntPtr.Zero) { AppLog.Write(L.T("自动发现不可用，iPhone 上需要手动填 IP。", "Auto-discovery unavailable; enter the IP on the iPhone.")); return; }
            _callback = (status, _, _) =>
            {
                if (status == 0) AppLog.Write(L.T("自动发现已开启，iPhone 能直接看到这台电脑。", "Auto-discovery on: the iPhone app will find this PC."));
                else AppLog.Write(L.T($"自动发现注册失败（{status}），iPhone 上请手动填 IP。", $"Auto-discovery failed ({status}); enter the IP on the iPhone."));
            };
            _req = new DNS_SERVICE_REGISTER_REQUEST
            {
                Version = 1,
                pServiceInstance = inst,
                pRegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(_callback),
            };
            var rc = DnsServiceRegister(ref _req, IntPtr.Zero);
            _registered = rc == 9506; // DNS_REQUEST_PENDING
            if (!_registered) AppLog.Write(L.T($"自动发现注册失败（{rc}），iPhone 上请手动填 IP。", $"Auto-discovery failed ({rc}); enter the IP on the iPhone."));
        }
        catch (Exception e)
        {
            AppLog.Write(L.T($"自动发现不可用：{e.Message}", $"Auto-discovery unavailable: {e.Message}"));
        }
    }

    public static void Unregister()
    {
        if (!_registered) return;
        try { DnsServiceDeRegister(ref _req, IntPtr.Zero); } catch { }
        _registered = false;
    }
}
