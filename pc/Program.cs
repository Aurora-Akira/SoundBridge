using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace PcAudioRelay;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        int port = AppInfo.DefaultPort;
        bool noBonjour = false, minimized = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--port" && i + 1 < args.Length && int.TryParse(args[i + 1], out var p)) port = p;
            if (args[i] == "--no-bonjour") noBonjour = true;
            if (args[i] == "--minimized") minimized = true;
        }

        // 只允许开一个：再次打开时把已有的窗口叫出来
        using var mutex = new Mutex(true, $"SoundBridge-{port}", out bool first);
        using var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, $"SoundBridge-Show-{port}");
        if (!first)
        {
            showSignal.Set();
            return;
        }

        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var server = new RelayServer();
        try { server.Start(port); }
        catch (SocketException e)
        {
            MessageBox.Show(L.T($"端口 {port} 无法使用：{e.Message}", $"Port {port} is unavailable: {e.Message}"),
                L.T("声桥", "SoundBridge"), MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        var ips = LanAddresses();
        if (!noBonjour) Bonjour.Register(Environment.MachineName, port, ips.FirstOrDefault());

        var source = new LoopbackSource(server);
        var form = new MainForm(server, source, ips, startHidden: minimized);

        var listener = new Thread(() =>
        {
            while (showSignal.WaitOne())
            {
                try { if (form.IsHandleCreated) form.BeginInvoke(form.ShowFromTray); } catch { }
            }
        }) { IsBackground = true };
        listener.Start();

        source.Start();
        Application.Run(form);

        Bonjour.Unregister();
        source.Dispose();
        server.Stop();
    }

    /// <summary>本机局域网 IPv4（排除虚拟网卡、代理、WSL）</summary>
    public static List<IPAddress> LanAddresses()
    {
        var list = new List<IPAddress>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
            var name = (ni.Name + " " + ni.Description).ToLowerInvariant();
            if (name.Contains("vethernet") || name.Contains("virtual") || name.Contains("clash") || name.Contains("tap") ||
                name.Contains("wsl") || name.Contains("vmware") || name.Contains("vpn") || name.Contains("tun")) continue;
            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var b = ua.Address.GetAddressBytes();
                bool priv = b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
                if (priv) list.Add(ua.Address);
            }
        }
        return list;
    }
}
