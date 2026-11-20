using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private static readonly int[] ReconnectDelays = [1, 2, 5, 10, 30];
    private CancellationTokenSource? reconnecting;

    /// A dropped connection comes back by itself only when that needs no secret: a key file without a passphrase.
    /// Passwords and passphrases are never kept after connecting, so those hosts ask the user to connect again.
    private void OnDisconnected(RemoteAgent lost, string error)
    {
        if (agent != lost) return;
        busy = false; status.Text = ConnectionAdvice.Explain(error); RefreshWorkbench();
        if (host is { KeyFile: { Length: > 0 } } profile) _ = ReconnectAsync(profile);
    }

    /// Hosts from the user's OpenSSH config, offered when adding a server. An unreadable config offers nothing.
    private static List<SshConfig.Entry> ConfiguredHosts()
    {
        try { return File.Exists(SshConfig.DefaultPath) ? SshConfig.Parse(File.ReadAllText(SshConfig.DefaultPath), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) : []; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    private async Task ReconnectAsync(HostProfile profile)
    {
        reconnecting?.Cancel(); var attempt = reconnecting = new CancellationTokenSource();
        for (int i = 0; !attempt.IsCancellationRequested; i++)
        {
            int delay = ReconnectDelays[Math.Min(i, ReconnectDelays.Length - 1)];
            status.Text = $"连接已断开，{delay} 秒后自动重连…";
            try { await Task.Delay(TimeSpan.FromSeconds(delay), attempt.Token); } catch (OperationCanceledException) { return; }
            if (host != profile) return; // The user picked another host meanwhile.
            var next = new RemoteAgent();
            bool trusted = true;
            try
            {
                status.Text = "正在重新连接…";
                // An unknown or changed fingerprint is never accepted without the user: stop and let them connect by hand.
                await next.ConnectAsync(profile, "", "", ServerResources, fingerprint =>
                    Task.FromResult(trusted = local.Fingerprints.GetValueOrDefault(LocalState.HostKey(profile)) == fingerprint),
                    (hop, fingerprint) => Task.FromResult(trusted = local.Fingerprints.GetValueOrDefault(LocalState.HostKey(hop)) == fingerprint));
            }
            catch (RemoteSetupException) { next.Dispose(); status.Text = "已重新连上 SSH，但服务器需要重新设置，请手动连接"; return; }
            catch (Exception e) when (e is Renci.SshNet.Common.SshAuthenticationException or Renci.SshNet.Common.SshPassPhraseNullOrEmptyException or FileNotFoundException)
            { next.Dispose(); status.Text = "自动重连失败：" + ConnectionAdvice.Explain(e.Message); return; }
            catch (Exception)
            {
                next.Dispose();
                if (!trusted) { status.Text = "自动重连已停止：主机指纹与上次不同，请核实服务器后手动连接"; return; }
                continue;
            }
            if (attempt.IsCancellationRequested || host != profile) { next.Dispose(); return; }
            var tunnels = agent?.Tunnels ?? [];
            agent?.Dispose(); agent = next;
            foreach (var tunnel in tunnels) try { next.Forward(tunnel); } catch (IOException) { } // A port taken meanwhile is simply not restored.
            next.Disconnected += error => DispatcherQueue.TryEnqueue(() => OnDisconnected(next, error));
            await RunAsync(async () =>
            {
                // Keep the open conversation; a remote task that kept running is watched again.
                if (taskId is not null) await WatchCurrentAsync();
                await RefreshHistoryAsync(); await RefreshCapabilitiesAsync(); await RefreshHealthAsync();
                status.Text = "已重新连接";
            });
            RefreshWorkbench();
            return;
        }
    }

    private readonly StackPanel tunnelList = new() { Spacing = 6 };

    /// Port forwarding: a port on the server's loopback opened at 127.0.0.1 on this computer, until it is closed or the app disconnects.
    private FrameworkElement TunnelPanel()
    {
        var localPort = new NumberBox { Header = "本地端口", Minimum = 1, Maximum = 65535, Width = 120 };
        var remotePort = new NumberBox { Header = "服务器端口", Minimum = 1, Maximum = 65535, Width = 120 };
        var add = Button("转发", () =>
        {
            if (double.IsNaN(localPort.Value) || double.IsNaN(remotePort.Value)) throw new IOException("请填写两个端口");
            RequireSsh().Forward(new Tunnel((int)localPort.Value, (int)remotePort.Value));
            localPort.Value = double.NaN; remotePort.Value = double.NaN; RenderTunnels();
            return Task.CompletedTask;
        });
        add.VerticalAlignment = VerticalAlignment.Bottom;
        var panel = new StackPanel { Spacing = 12, Width = 340 };
        panel.Children.Add(new TextBlock { Text = "端口转发", FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ink });
        panel.Children.Add(new TextBlock { Text = "把服务器上只在本机监听的端口（例如开发服务器）接到这台电脑的 127.0.0.1。", FontSize = 12, Foreground = muted, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(Row(localPort, remotePort, add)); panel.Children.Add(tunnelList);
        RenderTunnels();
        return panel;
    }

    private RemoteAgent RequireSsh() => agent is { SshConnected: true } connected ? connected : throw new IOException("请先连接服务器");

    private void RenderTunnels()
    {
        tunnelList.Children.Clear();
        foreach (var tunnel in agent?.Tunnels ?? [])
        {
            var open = new HyperlinkButton { Content = $"localhost:{tunnel.LocalPort} → 服务器 {tunnel.RemotePort}", NavigateUri = new Uri($"http://127.0.0.1:{tunnel.LocalPort}"), Padding = new Thickness(0) };
            var close = Button("关闭", () => { agent?.CloseForward(tunnel.LocalPort); RenderTunnels(); return Task.CompletedTask; });
            tunnelList.Children.Add(Row(open, close));
        }
        if (tunnelList.Children.Count == 0) tunnelList.Children.Add(new TextBlock { Text = "还没有转发的端口", FontSize = 12, Foreground = muted });
    }
}
