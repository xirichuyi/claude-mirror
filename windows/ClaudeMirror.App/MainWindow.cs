using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace ClaudeMirror.App;

public sealed partial class MainWindow : Window
{
    private readonly Grid root = new();
    private readonly StackPanel sidebar = new() { Spacing = 12, Padding = new Thickness(16) };
    private readonly StackPanel projects = new() { Spacing = 8 };
    private readonly StackPanel messages = new() { Spacing = 18, Padding = new Thickness(24) };
    private readonly ScrollViewer scroll = new();
    private readonly TextBox prompt = new() { PlaceholderText = "发消息，/ 命令", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90, MaxHeight = 220 };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    private readonly ComboBox hosts = new() { PlaceholderText = "选择主机", HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Name" };
    private List<ModelChoice> availableModels = [];
    private List<string> availableCommands = [];
    private ModelChoice? selectedModel;
    private readonly LocalState local = new(StateFolder());
    private readonly TextBox directory = new() { Text = "~", PlaceholderText = "远端工作目录" };
    private RemoteAgent? agent;
    private HostProfile? host;
    private Conversation? conversation;
    private string? taskId;
    private string? taskKey;
    private bool busy;
    private MessageView? reply;
    private SendQueue queue = new();
    private JsonObject? lastState;
    /// The first prompt of a conversation the server has not named yet.
    private string? newTitle;
    private bool sending;
    private sealed record ModelChoice(string Value, string Label, bool Auto = false);
    private static SolidColorBrush Brush(byte r, byte g, byte b) => new(Windows.UI.Color.FromArgb(255, r, g, b));

    public MainWindow()
    {
        Title = "claude-mirror · Windows";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 820));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        BuildWorkbench();
        prompt.AllowDrop = true;
        prompt.DragOver += (_, e) => { if (e.DataView.Contains(StandardDataFormats.StorageItems)) e.AcceptedOperation = DataPackageOperation.Copy; };
        prompt.Drop += async (_, e) => await RunAsync(async () => { foreach (var file in await e.DataView.GetStorageItemsAsync()) if (file is Windows.Storage.StorageFile) await AttachAsync(file.Path); });
        Closed += (_, _) => agent?.Dispose();
        StartCheckingUpdates();
        RefreshWorkbench();
        PrepareDemo();
    }
    private static StackPanel Row(params UIElement[] items)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var item in items) row.Children.Add(item); return row;
    }
    private Button Button(string label, Func<Task> action)
    {
        var button = new Button { Content = label }; button.Click += async (_, _) => await RunAsync(action); return button;
    }
    private async Task RunAsync(Func<Task> action)
    {
        try { await action(); } catch (Exception e) { status.Text = e.Message; }
    }
    private Task<bool> ConfirmHostAsync(HostProfile profile, string fingerprint)
    {
        var key = LocalState.HostKey(profile);
        if (local.Fingerprints.TryGetValue(key, out var previous))
        {
            if (previous != fingerprint) throw new IOException("主机指纹已变化，已拒绝连接");
            return Task.FromResult(true);
        }
        var result = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        DispatcherQueue.TryEnqueue(async () =>
        {
            try
            {
                var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "确认 SSH 主机", Content = profile.Host + "\n" + fingerprint, PrimaryButtonText = "信任并连接", CloseButtonText = "取消" };
                var accepted = await dialog.ShowAsync() == ContentDialogResult.Primary;
                if (accepted) { local.Fingerprints[key] = fingerprint; local.Save(); }
                result.TrySetResult(accepted);
            }
            catch (Exception e) { result.TrySetException(e); }
        });
        return result.Task;
    }
    private async Task ConnectDialogAsync(HostProfile? existing)
    {
        var name = new TextBox { Header = "显示名称", Text = existing?.Name ?? "", PlaceholderText = "例如：开发服务器（可选）" };
        var address = new TextBox { Header = "服务器地址", Text = existing is null ? "" : existing.User.Length > 0 ? existing.User + "@" + existing.Host : existing.Host, PlaceholderText = "例如 ubuntu@192.168.1.10" };
        var user = new TextBox { Header = "用户名", PlaceholderText = "地址里没写 用户名@ 时填写" };
        var port = new NumberBox { Header = "端口", Value = existing is null ? 22 : existing.Port > 0 ? existing.Port : double.NaN, Minimum = 1, Maximum = 65535 };
        var mode = new ComboBox { Header = "登录方式", ItemsSource = new[] { "密码", "私钥文件", "系统 SSH（SSH 配置、ssh-agent、跳板机）" }, SelectedIndex = existing?.SystemSsh == true ? 2 : existing?.KeyFile is null ? 0 : 1 };
        var jump = new TextBox { Header = "跳板机（可选）", Text = existing?.Jump ?? "", PlaceholderText = "例如 ops@bastion.example.com，或 SSH 配置里的别名" };
        var password = new PasswordBox { Header = "密码", PlaceholderText = "服务器登录密码" }; var phrase = new PasswordBox { Header = "私钥口令（可选）" };
        var key = new TextBox { Header = "私钥文件", Text = existing?.KeyFile ?? "" };
        var pick = Button("选择私钥", async () => { var file = await PickAsync(); if (file is not null) key.Text = file; });
        var note = new TextBlock { Foreground = muted, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        void UpdateMode()
        {
            password.Visibility = mode.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
            phrase.Visibility = key.Visibility = pick.Visibility = mode.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            jump.Visibility = mode.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
            note.Text = mode.SelectedIndex switch
            {
                0 => "密码不保存",
                1 => "私钥不上传",
                _ => "使用本机 OpenSSH：~/.ssh/config、ssh-agent、跳板机。不能输入密码。"
            };
        }
        mode.SelectionChanged += (_, _) => UpdateMode(); UpdateMode();
        var jumpNote = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = danger, Visibility = Visibility.Collapsed };
        var advanced = new StackPanel { Spacing = 14 };
        foreach (var element in new UIElement[] { name, user, port }) advanced.Children.Add(element);
        var expander = new Expander { Header = "高级选项：名称、用户名、端口", Content = advanced, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            IsExpanded = existing is not null && (existing.Port != 22 || existing.Name != existing.Host) };
        var configured = existing is null ? ConfiguredHosts() : [];
        var import = new ComboBox { Header = "从 SSH 配置导入", PlaceholderText = "选择 ~/.ssh/config 里的主机", ItemsSource = configured.Select(entry => entry.Alias).ToList(), HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = configured.Count > 0 ? Visibility.Visible : Visibility.Collapsed };
        import.SelectionChanged += (_, _) =>
        {
            if (import.SelectedIndex < 0) return;
            var entry = configured[import.SelectedIndex];
            // OpenSSH logs in as the local account when the config names no user.
            var account = entry.User ?? Environment.UserName;
            name.Text = entry.Alias; address.Text = account + "@" + entry.Host; port.Value = entry.Port;
            key.Text = entry.KeyFile ?? ""; mode.SelectedIndex = entry.KeyFile is null ? 0 : 1;
            // A host behind a jump host is left to OpenSSH, which reads the whole config entry by its alias.
            if (entry.ProxyJump is not null) { address.Text = entry.Alias; port.Value = double.NaN; mode.SelectedIndex = 2; jump.Text = ""; }
            jumpNote.Text = entry.ProxyJump is null ? "" : $"经跳板机 {entry.ProxyJump}，已改用系统 SSH";
            jumpNote.Foreground = muted;
            jumpNote.Visibility = entry.ProxyJump is null ? Visibility.Collapsed : Visibility.Visible;
            expander.IsExpanded = entry.Port != 22;
        };
        var panel = new StackPanel { Spacing = 14 };
        panel.Children.Add(new TextBlock { Text = "Claude Code 和项目都在服务器上运行。", TextWrapping = TextWrapping.Wrap, Foreground = muted });
        foreach (var element in new UIElement[] { import, jumpNote, address, mode, password, key, pick, phrase, jump, note, expander }) panel.Children.Add(element);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = existing == null ? "添加服务器" : "连接服务器", Content = new ScrollViewer { Content = panel }, Background = canvas, PrimaryButtonText = "连接", CloseButtonText = "取消" };
        (string User, string Host) Target()
        {
            var text = address.Text.Trim(); var at = text.LastIndexOf('@');
            return at > 0 ? (text[..at], text[(at + 1)..]) : (user.Text.Trim(), text);
        }
        void Validate()
        {
            var (u, h) = Target();
            if (mode.SelectedIndex == 2)
            {
                // OpenSSH takes a missing user or port from its config.
                dialog.IsPrimaryButtonEnabled = SystemSsh.Safe(h) && (u.Length == 0 || SystemSsh.Safe(u)) && (jump.Text.Trim().Length == 0 || SystemSsh.SafeJump(jump.Text.Trim()));
                UpdateMode(); return;
            }
            dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(h) && !string.IsNullOrWhiteSpace(u) && port.Value is >= 1 and <= 65535 && (mode.SelectedIndex == 0 || !string.IsNullOrWhiteSpace(key.Text));
            if (string.IsNullOrWhiteSpace(u) && !string.IsNullOrWhiteSpace(h)) { note.Text = "请在地址前写上用户名，例如 root@" + h + "，或在高级选项里填写。"; }
            else if (!string.IsNullOrWhiteSpace(h)) UpdateMode();
        }
        address.TextChanged += (_,_) => Validate(); user.TextChanged += (_,_) => Validate(); key.TextChanged += (_,_) => Validate(); jump.TextChanged += (_,_) => Validate();
        mode.SelectionChanged += (_,_) => Validate(); port.ValueChanged += (_,_) => Validate(); Validate();
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var (login, server) = Target();
        bool system = mode.SelectedIndex == 2;
        var profile = new HostProfile(string.IsNullOrWhiteSpace(name.Text) ? server : name.Text.Trim(), server, double.IsNaN(port.Value) ? 0 : (int)port.Value, login, mode.SelectedIndex == 1 ? key.Text : null,
            system, system && jump.Text.Trim().Length > 0 ? jump.Text.Trim() : null);
        // Queued prompts cannot follow the user to another server.
        if (host is not null && LocalState.HostKey(host) != LocalState.HostKey(profile)) await ConfirmLeavingQueueAsync(true);
        agent?.Dispose(); var next = new RemoteAgent(); agent = next; status.Text = "正在连接…"; health = [];
        reconnecting?.Cancel();
        next.Disconnected += error => DispatcherQueue.TryEnqueue(() => OnDisconnected(next, error));
        next.Slow += slow => DispatcherQueue.TryEnqueue(() => OnSlow(next, slow));
        RemoteSetupException? setup = null;
        var usedPassword = mode.SelectedIndex == 0;
        try { await next.ConnectAsync(profile, password.Password, phrase.Password, ServerResources, fingerprint => ConfirmHostAsync(profile, fingerprint)); }
        catch (RemoteSetupException e) { setup = e; }
        catch (SystemSshException e) when (e.Kind == SystemSshFailure.HostKey) { next.Dispose(); RefreshWorkbench(); await OfferTerminalLoginAsync(profile, e.Message); throw; }
        catch (SystemSshException) { next.Dispose(); RefreshWorkbench(); throw; }
        catch (Exception e) { next.Dispose(); RefreshWorkbench(); throw new IOException(ConnectionAdvice.Explain(e.Message), e); }
        finally { password.Password = ""; phrase.Password = ""; }
        host = profile; local.Hosts.RemoveAll(h => LocalState.HostKey(h) == LocalState.HostKey(profile)); local.Hosts.Add(profile); local.Save();
        hosts.ItemsSource = local.Hosts.ToList(); hosts.SelectedItem = profile;
        if (setup is not null)
        {
            // SSH works; the server only needs setting up. Keep the connection for one-click install.
            health = MachineHealth.Issues(setup, null, null); status.Text = "SSH 已连接，服务器还需要设置"; RenderHealth();
            return;
        }
        await AfterAgentStartedAsync(next);
        await RefreshHealthAsync();
        if (usedPassword) await RunAsync(() => OfferKeyLoginAsync(profile, next));
    }
    private RemoteAgent RequireAgent() => agent?.Connected == true ? agent : throw new IOException(agent?.SshConnected == true ? "服务器需要设置" : "请先连接服务器");
    private async Task RefreshHistoryAsync()
    {
        var remote = RequireAgent(); var sessions = new List<Conversation>(); var unread = new List<string>();
        // Conversations run as another account keep their transcripts in that account's home.
        foreach (var account in new string?[] { null }.Concat(local.Accounts.GetValueOrDefault(LocalState.HostKey(host!)) ?? []))
        {
            object offset = 0;
            try
            {
                do
                {
                    var page = await remote.CallAsync("history", new { operation = "list", offset, account });
                    foreach (var item in page["sessions"]!.AsArray()) sessions.Add(new(item!["name"]!.GetValue<string>(), item["directory"]?.GetValue<string>() ?? remote.Home, item["sessionId"]?.GetValue<string>(), item["reference"]?.GetValue<string>(), account));
                    if (page["nextOffset"] is null) break; offset = page["nextOffset"]!.GetValue<string>();
                } while (true);
            }
            catch (IOException) when (account is not null) { unread.Add(account); }
        }
        history = sessions; RenderHistory(); RefreshWorkbench();
        status.Text = $"已同步 {sessions.Count} 条会话" + (unread.Count > 0 ? "；读不到执行账号 " + string.Join("、", unread) + " 的历史" : "");
    }
    private Task NewConversationAsync() => NewConversationAsync(null);
    /// <param name="path">The project to start in. It is set once the open conversation has been left, which may be refused.</param>
    private async Task NewConversationAsync(string? path)
    {
        await LeaveConversationAsync();
        if (path is not null) directory.Text = path;
        UseAccount(null); RenderQueue(); RenderPermissions(null, null); RefreshWorkbench(); RenderHistory();
        if (agent?.Connected == true) await RefreshCapabilitiesAsync();
    }
    /// Queued prompts belong to the open conversation. Leaving it asks first; declining keeps the conversation and stops the caller.
    /// <param name="everywhere">Also count the prompts queued in background conversations, as when leaving the server.</param>
    private async Task ConfirmLeavingQueueAsync(bool everywhere = false)
    {
        int count = queue.Items.Count + (everywhere ? parked.Values.Sum(p => p.Queue.Items.Count) : 0);
        if (count == 0) return;
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot, Title = "还有未发送的消息", Content = everywhere ? $"{count} 条排队消息将被丢弃" : $"{count} 条排队消息将被丢弃",
            PrimaryButtonText = "丢弃并离开", CloseButtonText = "留在这里", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) throw new IOException("已保留当前对话和未发送的消息");
    }
    private async Task SelectAsync(Conversation selected)
    {
        if (IsCurrent(selected))
        {
            // Reopening the open conversation reloads it and keeps its queued prompts; while it is replying there is nothing to reload.
            if (busy || sending) return;
        }
        else
        {
            var waiting = ParkedFor(selected);
            if (waiting?.Sending == true) throw new IOException("正在发送排队消息，请稍候");
            await LeaveConversationAsync();
            // Left running earlier: it comes back as it was, with whatever arrived since.
            if (waiting is not null && parked.ContainsKey(waiting.TaskId)) { await RestoreAsync(waiting); return; }
            UseAccount(selected.Account);
        }
        conversation = selected; directory.Text = selected.Directory; messages.Children.Clear(); reply = null; lastState = null; RenderQueue(); RenderPermissions(null, null);
        RefreshWorkbench(); RenderHistory();
        var page = await RequireAgent().CallAsync("history", new { operation = "messages", reference = selected.Reference, account = selected.Account });
        foreach (var message in History.Messages(page["records"] as JsonArray)) AddMessage("", Presentation.Text(message["role"]) == "user").Show(message);
        taskKey = LocalState.HostKey(host!) + "|" + selected.SessionId;
        taskId = local.Tasks.GetValueOrDefault(taskKey);
        if (taskId is not null) await WatchCurrentAsync();
        await RefreshCapabilitiesAsync();
    }
    private async Task RefreshCapabilitiesAsync()
    {
        try
        {
            var remote = RequireAgent(); var caps = await remote.CallAsync("task", new { operation = "inspect", digest = remote.Digest, directory = directory.Text, action = "catalogue", preferences = new { executionUser } });
            availableModels = caps["models"]?.AsArray().Select(m => new ModelChoice(m!["value"]!.GetValue<string>(), m["displayName"]?.GetValue<string>() ?? m["value"]!.GetValue<string>(), m["supportsAutoMode"]?.GetValue<bool>() == true)).ToList() ?? [];
            availableCommands = caps["commands"]?.AsArray().Select(c => c!["name"]!.GetValue<string>()).ToList() ?? [];
        }
        catch (Exception e) { status.Text = "能力读取失败：" + e.Message; }
    }
    /// `now` hands the message to the running reply instead of waiting for it to end.
    private async Task SendAsync(bool now = false)
    {
        if (string.IsNullOrWhiteSpace(prompt.Text)) return;
        if (conversation is not null && directory.Text != conversation.Directory)
            throw new IOException("切换工作目录请新建对话");
        RequireAgent();
        var text = prompt.Text; prompt.Text = "";
        // The remote task refuses a second prompt while it is replying, so hold it here and send it when the reply ends.
        if (busy) { var item = queue.Add(text); RenderQueue(); if (now) await SteerAsync(item.Id); return; }
        queue.Resume();
        await SendTextAsync(text);
    }
    private async Task SendTextAsync(string text)
    {
        var remote = RequireAgent(); busy = true; sending = true; stopping = false; if (conversation is null && taskId is null) newTitle = Presentation.FirstLine(text, 40); AddMessage(text, true); reply = AddMessage("正在回复…"); RenderQueue(); RefreshWorkbench();
        var message = new { id = Guid.NewGuid().ToString(), role = "assistant", blocks = Array.Empty<object>() };
        try
        {
            if (taskId is null)
            {
                taskId = Guid.NewGuid().ToString(); taskKey = LocalState.HostKey(host!) + "|" + (conversation?.SessionId ?? taskId);
                local.Tasks[taskKey] = taskId; local.RememberAccount(LocalState.HostKey(host!), executionUser); local.Save();
                await remote.CallAsync("task", new { operation = "start", taskId, digest = remote.Digest, request = new { session = new { id = Guid.NewGuid().ToString(), host = host!.Host, directory = directory.Text, name = "Windows 对话", remoteSessionId = conversation?.SessionId, messages = new[] { message }, permissions = Array.Empty<object>(), preferences = new { selectedModel = selectedModel?.Value ?? "", permissionMode, executionUser } }, prompt = text } });
                await WatchCurrentAsync();
            }
            else
            {
                await remote.TaskCommandAsync(taskId, new { kind = "control", action = "model", value = selectedModel?.Value ?? "" });
                await remote.TaskCommandAsync(taskId, new { kind = "control", action = "permission", value = permissionMode });
                await remote.TaskCommandAsync(taskId, new { kind = "send", prompt = text, message });
            }
        }
        catch { busy = false; queue.Pause(); RenderQueue(); RefreshWorkbench(); status.Text = "未确认送达，请重连查看"; throw; }
        finally { sending = false; }
    }
    /// Sends a queued message now. While Claude replies it joins that reply and Claude reads it at its next step;
    /// otherwise it goes out as the next prompt.
    private async Task SteerAsync(string id)
    {
        if (queue.Take(id) is not { } item) return;
        RenderQueue();
        if (!busy) { queue.Resume(); await SendTextAsync(item.Text); return; }
        // The task is still starting or stopping: the message stays first in line.
        if (taskId is null || sending || stopping) { queue.Restore(item); RenderQueue(); return; }
        var owner = queue;
        try { await RequireAgent().TaskCommandAsync(taskId, new { kind = "steer", id = item.Id, text = item.Text, prompt = item.Text }); }
        catch
        {
            // Another conversation was opened meanwhile: the message goes back to its own queue, which went with its conversation.
            if (!ReferenceEquals(queue, owner)) { owner.Restore(item); throw; }
            // Only the acknowledgement was lost: the reply already shows the message.
            if (Steered(item.Id)) return;
            // The reply ended first or the link dropped. The message returns to the head of the queue, never lost.
            queue.Restore(item); RenderQueue();
            if (busy || queue.Paused) throw;
            if (queue.Next(busy) is { } next) { RenderQueue(); await SendTextAsync(next.Text); }
        }
    }
    private bool Steered(string id) => lastState?["message"]?["blocks"] is JsonArray blocks && blocks.Any(block =>
        Presentation.Text(block?["type"]) == "user" && Presentation.Text(block?["id"]) == id && block?["cancelled"]?.GetValue<bool>() != true);
    private Task WatchCurrentAsync()
    {
        var watched = taskId!;
        return RequireAgent().WatchAsync(watched, state => OnState(watched, state));
    }
    private void OnState(string watched, JsonObject state) => DispatcherQueue.TryEnqueue(async () =>
    {
        if (taskId == watched) await ApplyStateAsync(watched, state);
        // A conversation left running in the background keeps its own state and queue.
        else if (parked.TryGetValue(watched, out var background)) await BackgroundStateAsync(background, state);
    });
    private async Task ApplyStateAsync(string watched, JsonObject state)
    {
        bool wasBusy = busy; lastState = state;
        // The model and permission commands sent before a prompt publish idle snapshots; those must not release the next queued prompt.
        busy = Turn.Busy(state, sending);
        reply ??= AddMessage(""); reply.Show(state["message"], busy);
        if (state["tasks"] is JsonArray tasks) backgroundTasks = (JsonArray)tasks.DeepClone();
        // A reply that failed or was stopped keeps the queue until the user says to go on.
        if (wasBusy && !busy && Turn.Failed(state)) queue.Pause();
        if (!busy) stopping = false;
        status.Text = busy ? "正在回复" : "就绪";
        if (state["remoteSessionId"] is JsonValue session && taskId is not null)
        {
            var sessionId = session.GetValue<string>();
            conversation = new Conversation(conversation?.Name ?? newTitle ?? "Windows 对话", directory.Text, sessionId, conversation?.Reference, executionUser.Length > 0 ? executionUser : null);
            local.Tasks[LocalState.HostKey(host!) + "|" + sessionId] = taskId; local.Save();
        }
        if (state["done"]?.GetValue<bool>() == true)
        {
            foreach (var key in local.Tasks.Where(pair => pair.Value == watched).Select(pair => pair.Key).ToList()) local.Tasks.Remove(key);
            local.Save(); taskId = null; busy = false;
        }
        RefreshWorkbench();
        if (queue.Next(busy) is { } next) { RenderQueue(); RenderPermissions(watched, null); await RunAsync(() => SendTextAsync(next.Text)); return; }
        RenderQueue();
        RenderPermissions(watched, state["permissions"] as JsonArray);
    }
    /// True from the stop request until the reply ends.
    private bool stopping;
    private async Task StopAsync()
    {
        queue.Pause(); RenderQueue();
        if (taskId is null) return;
        stopping = true; UpdateActions();
        try { await RequireAgent().TaskCommandAsync(taskId, new { kind = "stop" }); }
        catch { stopping = false; UpdateActions(); throw; }
    }
    private async Task<string?> PickAsync()
    {
        var picker = new FileOpenPicker(); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this)); picker.FileTypeFilter.Add("*");
        return (await picker.PickSingleFileAsync())?.Path;
    }
    private async Task UploadAsync() { RequireAgent(); var file = await PickAsync(); if (file is not null) await AttachAsync(file); }
    private async Task AttachAsync(string file) { status.Text = "上传中…"; var path = await RequireAgent().UploadAsync(file, executionUser); prompt.Text += "\n附件：" + path; status.Text = "已上传"; }
    private async Task BrowseAsync()
    {
        var remote = RequireAgent(); var path = new TextBox { Text = directory.Text }; var entries = new StackPanel { Spacing = 4 };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(path); panel.Children.Add(new ScrollViewer { Content = entries, MaxHeight = 400 });
        ContentDialog? browser = null; string? previewPath = null;
        // The window's status line is behind this dialog, so a failed create, rename or delete is reported here.
        var problem = new TextBlock { Foreground = danger, FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed }; panel.Children.Add(problem);
        async Task Guard(Func<Task> action)
        {
            try { problem.Visibility = Visibility.Collapsed; await action(); }
            catch (Exception e) { problem.Text = e.Message; problem.Visibility = Visibility.Visible; }
        }
        async Task Load()
        {
            var result = await remote.CallAsync("file", new { operation = "list", path = path.Text, @base = directory.Text });
            path.Text = result["path"]!.GetValue<string>(); entries.Children.Clear();
            entries.Children.Add(Button("↑ 上一级", async () => { path.Text = path.Text.TrimEnd('/')[..Math.Max(0, path.Text.TrimEnd('/').LastIndexOf('/'))]; if (path.Text.Length == 0) path.Text = "/"; await Load(); }));
            foreach (var entry in result["entries"]!.AsArray())
            {
                var item = entry!.DeepClone();
                bool folder = item["directory"]?.GetValue<bool>() == true || item["type"]?.GetValue<string>() == "directory";
                var row = Button(item["name"]!.GetValue<string>(), async () =>
                {
                    if (folder) { path.Text = item["path"]!.GetValue<string>(); await Load(); }
                    else { previewPath = item["path"]!.GetValue<string>(); browser!.Hide(); }
                });
                row.ContextFlyout = EntryMenu(remote, row, item["path"]!.GetValue<string>(), item["name"]!.GetValue<string>(), folder, Load, Guard);
                entries.Children.Add(row);
            }
        }
        var create = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        create.Children.Add(Button("前往", Load));
        foreach (var makeFolder in new[] { false, true })
        {
            var name = new TextBox { PlaceholderText = makeFolder ? "文件夹名称" : "文件名称", Width = 220 };
            var add = Button(makeFolder ? "新建文件夹" : "新建文件", () => Task.CompletedTask);
            var flyout = new Flyout();
            flyout.Content = new StackPanel { Spacing = 8, Children = { name, Button("创建", () => { flyout.Hide(); return Guard(async () =>
            {
                await remote.CallAsync("file", new { operation = "create", directory = path.Text, name = name.Text.Trim(), folder = makeFolder });
                name.Text = ""; await Load();
            }); }) } };
            add.Flyout = flyout; create.Children.Add(add);
        }
        panel.Children.Add(create); await Load();
        browser = new ContentDialog { XamlRoot = root.XamlRoot, Title = "远端文件", Content = panel, PrimaryButtonText = "设为工作目录", CloseButtonText = "关闭" };
        if (await browser.ShowAsync() == ContentDialogResult.Primary)
        {
            await NewConversationAsync(); directory.Text = path.Text; await RefreshCapabilitiesAsync();
        }
        if (previewPath is not null) await PreviewAsync(previewPath);
    }
    /// Rename and delete for one entry of the remote file browser. Deleting asks again inside the menu, because a second dialog cannot open over the browser.
    private MenuFlyout EntryMenu(RemoteAgent remote, FrameworkElement anchor, string path, string name, bool folder, Func<Task> reload, Func<Func<Task>, Task> guard)
    {
        var menu = new MenuFlyout();
        var renamed = new TextBox { Text = name, Width = 240 };
        var rename = new Flyout();
        rename.Content = new StackPanel { Spacing = 8, Children = { renamed, Button("重命名", () => { rename.Hide(); return guard(async () =>
        {
            if (openFiles.Any(file => file.Path == path || file.Path.StartsWith(path + "/", StringComparison.Ordinal))) throw new IOException("请先关闭这个文件的标签，再重命名");
            await remote.CallAsync("file", new { operation = "rename", path, name = renamed.Text.Trim() });
            await reload();
        }); }) } };
        var start = new MenuFlyoutItem { Text = "重命名…", Icon = new FontIcon { Glyph = "\uE8AC" } };
        start.Click += (_, _) => rename.ShowAt(anchor);
        menu.Items.Add(start);
        var delete = new MenuFlyoutSubItem { Text = "删除", Icon = new FontIcon { Glyph = "\uE74D" } };
        delete.Items.Add(MenuItem(folder ? $"确认删除文件夹“{name}”及其全部内容" : $"确认删除“{name}”", "\uE74D", () => guard(async () =>
        {
            if (openFiles.Any(file => file.Dirty && (file.Path == path || file.Path.StartsWith(path + "/", StringComparison.Ordinal)))) throw new IOException("请先保存或关闭文件");
            await remote.CallAsync("file", new { operation = "remove", path, recursive = folder });
            await reload();
        })));
        menu.Items.Add(delete);
        return menu;
    }
    private async Task PreviewAsync(string path)
    {
        var remote = RequireAgent(); var preview = await remote.CallAsync("file", new { operation = "preview", path, @base = directory.Text });
        if (!ReferenceEquals(remote,agent) || host==null) return;
        if ((string?)preview["kind"]=="text") { OpenTextEditor(path,LocalState.HostKey(host),preview);return; }
        if ((string?)preview["kind"]=="pdf") { await OpenPdfAsync(path);return; }
        UIElement content = new TextBlock { Text = preview["text"]?.GetValue<string>() ?? "此文件请下载后查看", IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        if (preview["kind"]?.GetValue<string>() == "image")
        {
            var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + Path.GetExtension(path)); await remote.DownloadAsync(path, file);
            var bitmap = new BitmapImage(); using (var stream = await Windows.Storage.Streams.RandomAccessStreamReference.CreateFromFile(await Windows.Storage.StorageFile.GetFileFromPathAsync(file)).OpenReadAsync()) { await bitmap.SetSourceAsync(stream); }
            File.Delete(file); content = new Image { Source = bitmap, MaxWidth = 700, MaxHeight = 500 };
        }
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = Path.GetFileName(path), Content = new ScrollViewer { Content = content, MaxHeight = 500 }, PrimaryButtonText = "下载", CloseButtonText = "关闭" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await SaveCopyAsync(path);
    }
    /// Downloads a server file to a place the user picks.
    private async Task SaveCopyAsync(string path)
    {
        var remote = RequireAgent();
        var picker = new FileSavePicker { SuggestedFileName = Path.GetFileName(path) }; picker.FileTypeChoices.Add("文件", new List<string> { Path.GetExtension(path) is { Length: > 0 } ext ? ext : ".bin" });
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this)); var file = await picker.PickSaveFileAsync(); if (file is not null) await remote.DownloadAsync(path, file.Path);
    }
}
