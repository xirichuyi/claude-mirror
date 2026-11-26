using System.Diagnostics;
using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace ClaudeMirror.App;

/// Server setup for new users: the environment checklist, one-click install, Claude login and password-free login.
public sealed partial class MainWindow
{
    private List<HealthIssue> health = [];
    private readonly StackPanel healthPanel = new() { Spacing = 10 };
    private static readonly Uri GettingStartedUrl = new("https://github.com/xirichuyi/claude-mirror/blob/HEAD/docs/getting-started.md");
    private static string ServerResources => Path.Combine(AppContext.BaseDirectory, "server");

    private async Task RefreshHealthAsync()
    {
        if (agent?.Connected != true) return;
        var current = agent;
        try
        {
            var claude = await current.ClaudeStatusAsync();
            if (current != agent) return;
            health = MachineHealth.Issues(null, current.Hello, claude);
        }
        catch (Exception e) { status.Text = "检查服务器失败：" + e.Message; }
        RenderHealth();
    }

    /// After installing or logging in: restart the agent if it never started, then check again.
    private async Task RecheckAsync()
    {
        if (agent is null || !agent.SshConnected) { await ConnectDialogAsync(host); return; }
        if (!agent.Connected)
        {
            try { await agent.StartAgentAsync(ServerResources); }
            catch (RemoteSetupException e) { health = MachineHealth.Issues(e, null, null); RenderHealth(); return; }
            await AfterAgentStartedAsync(agent);
        }
        await RefreshHealthAsync();
        if (health.Count == 0) status.Text = (host?.Name ?? "服务器") + " 已准备就绪";
    }

    private string? sessionHost;

    private async Task AfterAgentStartedAsync(RemoteAgent connected)
    {
        availableModels.Clear(); availableCommands.Clear(); selectedModel = null; busy = false;
        health = MachineHealth.Issues(null, connected.Hello, null);
        var key = host is null ? null : LocalState.HostKey(host);
        // Connecting to the same server again keeps the open conversation and its queued prompts, as an automatic reconnect does.
        bool resumed = key is not null && key == sessionHost && (conversation is not null || taskId is not null || queue.Items.Count > 0 || parked.Count > 0);
        // Changes, diff, search, PDF and status tabs show the previous server's data, and their buttons would act on this one.
        // Background conversations belong to the previous server too; their tasks carry on there.
        if (key != sessionHost) { CloseToolTabs(); parked.Clear(); }
        sessionHost = key;
        if (resumed)
        {
            if (taskId is not null) await WatchCurrentAsync();
            await RewatchParkedAsync(connected);
            await RefreshCapabilitiesAsync(); RenderQueue(); RefreshWorkbench();
        }
        else { taskId = null; queue.Clear(); directory.Text = connected.Home; await NewConversationAsync(); }
        await RefreshHistoryAsync(); status.Text = "已连接";
        RenderHealth();
    }

    private void RenderHealth()
    {
        healthPanel.Children.Clear();
        healthPanel.Visibility = health.Count == 0 || agent?.SshConnected != true ? Visibility.Collapsed : Visibility.Visible;
        foreach (var issue in health)
        {
            var card = new StackPanel { Spacing = 6 };
            card.Children.Add(new TextBlock { Text = (issue.Blocking ? "⚠ " : "ⓘ ") + issue.Title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ink, TextWrapping = TextWrapping.Wrap });
            card.Children.Add(new TextBlock { Text = issue.Detail, Foreground = muted, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            var actions = Row();
            switch (issue.Action)
            {
                case HealthAction.Install: actions.Children.Add(Primary(Button("一键安装", InstallDialogAsync))); break;
                case HealthAction.Login:
                    actions.Children.Add(Primary(Button("在终端登录", () => { OpenTerminal(issue.Command!); return Task.CompletedTask; })));
                    actions.Children.Add(Button("复制登录命令", () => { Copy(issue.Command!, "已复制，SSH 登录服务器后运行即可"); return Task.CompletedTask; }));
                    break;
                case HealthAction.Copy:
                    actions.Children.Add(Button("复制命令", () => { Copy(issue.Command!, "已复制，请在服务器上运行"); return Task.CompletedTask; }));
                    break;
            }
            actions.Children.Add(Button("重新检查", RecheckAsync));
            card.Children.Add(actions);
            healthPanel.Children.Add(new Border { Child = card, Padding = new Thickness(12), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), BorderBrush = edge, Background = surface });
        }
        RefreshWorkbench();
    }

    /// The one main action of a page or card: the accent fill with white text, in every pointer state.
    private Button Primary(Button button)
    {
        foreach (var state in new[] { "", "PointerOver", "Pressed" }) { button.Resources["ButtonBackground" + state] = accentFill; button.Resources["ButtonForeground" + state] = onAccent; }
        button.Resources["ButtonBackgroundDisabled"] = edge; button.Resources["ButtonForegroundDisabled"] = dim;
        button.Background = accentFill; button.Foreground = onAccent; button.BorderThickness = new Thickness(0);
        return button;
    }

    private void Copy(string text, string note)
    {
        var package = new DataPackage(); package.SetText(text); Clipboard.SetContent(package); status.Text = note;
    }

    /// Opens a console on the server with Windows' built-in OpenSSH client.
    private void OpenTerminal(string remoteCommand)
    {
        if (host is null) return;
        var login = host.SystemSsh ? "ssh -t" + SystemSsh.TerminalCommand(host)[3..] : $"ssh -t -p {host.Port} {host.User}@{host.Host}";
        var target = $"{login} \"{remoteCommand.Replace("\"", "\\\"")}\"";
        try { Process.Start(new ProcessStartInfo("cmd.exe", "/k " + target) { UseShellExecute = true }); status.Text = "登录后点“重新检查”"; }
        catch { Copy(target, "已复制命令"); }
    }

    private async Task InstallDialogAsync()
    {
        var remote = agent ?? throw new IOException("请先连接服务器");
        var log = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Consolas"), FontSize = 12, Height = 240 };
        ScrollViewer.SetVerticalScrollBarVisibility(log, ScrollBarVisibility.Auto);
        var summary = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = ink };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = "安装到用户目录", TextWrapping = TextWrapping.Wrap, Foreground = muted });
        panel.Children.Add(log); panel.Children.Add(summary);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "设置 " + (host?.Name ?? "服务器"), Content = panel, PrimaryButtonText = "开始安装", CloseButtonText = "关闭", Background = canvas };
        using var cancel = new CancellationTokenSource();
        int? result = null;
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            e.Cancel = true; dialog.IsPrimaryButtonEnabled = false; log.Text = ""; summary.Text = "正在安装…";
            try
            {
                result = await remote.InstallAsync(ServerResources, line => DispatcherQueue.TryEnqueue(() => { log.Text += line + "\n"; log.SelectionStart = log.Text.Length; }), cancel.Token);
            }
            catch (Exception error) { log.Text += ConnectionAdvice.Explain(error.Message) + "\n"; result = 1; }
            summary.Text = RemoteInstaller.Summary(result ?? 1);
            dialog.PrimaryButtonText = "重新安装"; dialog.IsPrimaryButtonEnabled = true;
        };
        await dialog.ShowAsync();
        cancel.Cancel();
        if (result == 0) await RecheckAsync();
    }

    private static string? FindKeygen()
    {
        var system = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh-keygen.exe");
        if (File.Exists(system)) return system;
        return (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(folder => Path.Combine(folder, "ssh-keygen.exe")).FirstOrDefault(File.Exists);
    }

    /// Offered once after a password login: create a dedicated key, authorize it, prove it works, then switch.
    private async Task OfferKeyLoginAsync(HostProfile profile, RemoteAgent remote)
    {
        if (profile.SystemSsh || profile.KeyFile is not null || local.DeclinedKeyLogin.Contains(LocalState.HostKey(profile)) || FindKeygen() is not { } keygen) return;
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot, Title = "为 " + profile.Name + " 设置免密登录？", Background = canvas,
            Content = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = "%USERPROFILE%\\.ssh\\claude_mirror_ed25519 → ~/.ssh/authorized_keys" },
            PrimaryButtonText = "设置免密登录", SecondaryButtonText = "不再询问", CloseButtonText = "以后再说",
        };
        var choice = await dialog.ShowAsync();
        if (choice == ContentDialogResult.Secondary) { local.DeclinedKeyLogin.Add(LocalState.HostKey(profile)); local.Save(); return; }
        if (choice != ContentDialogResult.Primary) return;
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "claude_mirror_ed25519");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (!File.Exists(path))
        {
            var start = new ProcessStartInfo(keygen) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var argument in new[] { "-q", "-t", "ed25519", "-N", "", "-C", "claude-mirror", "-f", path }) start.ArgumentList.Add(argument);
            using var process = Process.Start(start)!; await process.WaitForExitAsync();
            if (process.ExitCode != 0) throw new IOException("无法生成登录密钥");
        }
        var publicKey = RemoteInstaller.ValidPublicKey(await File.ReadAllTextAsync(path + ".pub")) ?? throw new IOException("登录密钥无法读取");
        if (!(await remote.RunScriptAsync(RemoteInstaller.AuthorizeScript(publicKey))).Contains("__RCC_KEY_OK__")) throw new IOException("服务器没有确认添加密钥");
        var updated = profile with { KeyFile = path };
        try { await RemoteAgent.VerifyKeyLoginAsync(updated, local.Fingerprints[LocalState.HostKey(profile)]); }
        catch (Exception e) { throw new IOException("服务器不接受密钥登录，仍使用密码" + e.Message); }
        local.Hosts.RemoveAll(h => LocalState.HostKey(h) == LocalState.HostKey(profile)); local.Hosts.Add(updated); local.Save();
        host = updated; hosts.ItemsSource = local.Hosts.ToList(); hosts.SelectedItem = updated;
        status.Text = "已设置免密登录";
    }
}
