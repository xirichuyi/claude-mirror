using ClaudeMirror.Core;
using Microsoft.UI.Xaml;

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
                    Task.FromResult(trusted = local.Fingerprints.GetValueOrDefault(LocalState.HostKey(profile)) == fingerprint));
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
            agent?.Dispose(); agent = next;
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
}
