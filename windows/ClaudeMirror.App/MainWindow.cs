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
    private readonly TextBox prompt = new() { PlaceholderText = "发送消息，或输入 / 使用命令", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90, MaxHeight = 220 };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    private readonly ComboBox hosts = new() { PlaceholderText = "选择主机", HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Name" };
    private List<ModelChoice> availableModels = [];
    private List<string> availableCommands = [];
    private ModelChoice? selectedModel;
    private readonly LocalState local = new(Environment.GetEnvironmentVariable("CLAUDE_MIRROR_STATE_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "claude-mirror"));
    private readonly TextBox directory = new() { Text = "~", PlaceholderText = "远端工作目录" };
    private RemoteAgent? agent;
    private HostProfile? host;
    private Conversation? conversation;
    private string? taskId;
    private string? taskKey;
    private bool busy;
    private MessageView? reply;
    private readonly SemaphoreSlim permissionLock = new(1);
    private readonly HashSet<string> approvalDialogs = [];
    private sealed record ModelChoice(string Value, string Label);
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
            if (previous != fingerprint) throw new IOException("主机指纹发生变化，连接已拒绝。请核实服务器后更新本地信任记录。");
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
        var address = new TextBox { Header = "服务器地址", Text = existing is null ? "" : existing.User + "@" + existing.Host, PlaceholderText = "例如 ubuntu@192.168.1.10" };
        var user = new TextBox { Header = "用户名", PlaceholderText = "地址里没写 用户名@ 时填写" };
        var port = new NumberBox { Header = "端口", Value = existing?.Port ?? 22, Minimum = 1, Maximum = 65535 };
        var mode = new ComboBox { Header = "登录方式", ItemsSource = new[] { "密码", "私钥文件" }, SelectedIndex = existing?.KeyFile is null ? 0 : 1 };
        var password = new PasswordBox { Header = "密码", PlaceholderText = "服务器登录密码" }; var phrase = new PasswordBox { Header = "私钥口令（可选）" };
        var key = new TextBox { Header = "私钥文件", Text = existing?.KeyFile ?? "" };
        var pick = Button("选择私钥", async () => { var file = await PickAsync(); if (file is not null) key.Text = file; });
        var note = new TextBlock { Foreground = muted, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        void UpdateMode()
        {
            password.Visibility = mode.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
            phrase.Visibility = key.Visibility = pick.Visibility = mode.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            note.Text = mode.SelectedIndex == 0 ? "密码只用于这次连接，不会保存。连接成功后可以一键设置免密登录。首次连接会请你确认服务器指纹。" : "使用所选私钥登录，私钥不会上传。首次连接会请你确认服务器指纹。";
        }
        mode.SelectionChanged += (_, _) => UpdateMode(); UpdateMode();
        var advanced = new StackPanel { Spacing = 14 };
        foreach (var element in new UIElement[] { name, user, port }) advanced.Children.Add(element);
        var expander = new Expander { Header = "高级选项：名称、用户名、端口", Content = advanced, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            IsExpanded = existing is not null && (existing.Port != 22 || existing.Name != existing.Host) };
        var panel = new StackPanel { Spacing = 14 };
        panel.Children.Add(new TextBlock { Text = "填写服务器地址和登录方式。Claude Code 和项目都在服务器上运行，本机只负责显示和操作。", TextWrapping = TextWrapping.Wrap, Foreground = muted });
        foreach (var element in new UIElement[] { address, mode, password, key, pick, phrase, note, expander }) panel.Children.Add(element);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = existing == null ? "添加服务器" : "连接服务器", Content = new ScrollViewer { Content = panel }, Background = canvas, PrimaryButtonText = "连接", CloseButtonText = "取消" };
        (string User, string Host) Target()
        {
            var text = address.Text.Trim(); var at = text.LastIndexOf('@');
            return at > 0 ? (text[..at], text[(at + 1)..]) : (user.Text.Trim(), text);
        }
        void Validate()
        {
            var (u, h) = Target();
            dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(h) && !string.IsNullOrWhiteSpace(u) && port.Value is >= 1 and <= 65535 && (mode.SelectedIndex == 0 || !string.IsNullOrWhiteSpace(key.Text));
            if (string.IsNullOrWhiteSpace(u) && !string.IsNullOrWhiteSpace(h)) { note.Text = "请在地址前写上用户名，例如 root@" + h + "，或在高级选项里填写。"; }
            else if (!string.IsNullOrWhiteSpace(h)) UpdateMode();
        }
        address.TextChanged += (_,_) => Validate(); user.TextChanged += (_,_) => Validate(); key.TextChanged += (_,_) => Validate();
        mode.SelectionChanged += (_,_) => Validate(); port.ValueChanged += (_,_) => Validate(); Validate();
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var (login, server) = Target();
        var profile = new HostProfile(string.IsNullOrWhiteSpace(name.Text) ? server : name.Text.Trim(), server, (int)port.Value, login, mode.SelectedIndex == 1 ? key.Text : null);
        agent?.Dispose(); var next = new RemoteAgent(); agent = next; status.Text = "正在连接…"; health = [];
        next.Disconnected += error => DispatcherQueue.TryEnqueue(() => { if (agent == next) { status.Text = ConnectionAdvice.Explain(error); busy = false; RefreshWorkbench(); } });
        RemoteSetupException? setup = null;
        var usedPassword = mode.SelectedIndex == 0;
        try { await next.ConnectAsync(profile, password.Password, phrase.Password, ServerResources, fingerprint => ConfirmHostAsync(profile, fingerprint)); }
        catch (RemoteSetupException e) { setup = e; }
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
    private RemoteAgent RequireAgent() => agent?.Connected == true ? agent : throw new IOException(agent?.SshConnected == true ? "服务器还需要设置，请先按首页提示完成" : "请先连接服务器");
    private async Task RefreshHistoryAsync()
    {
        var remote = RequireAgent(); var sessions = new List<Conversation>(); object offset = 0;
        do
        {
            var page = await remote.CallAsync("history", new { operation = "list", offset });
            foreach (var item in page["sessions"]!.AsArray()) sessions.Add(new(item!["name"]!.GetValue<string>(), item["directory"]?.GetValue<string>() ?? remote.Home, item["sessionId"]?.GetValue<string>(), item["reference"]?.GetValue<string>()));
            if (page["nextOffset"] is null) break; offset = page["nextOffset"]!.GetValue<string>();
        } while (true);
        history = sessions; RenderHistory(); RefreshWorkbench();
        status.Text = $"已同步 {sessions.Count} 条会话";
    }
    private async Task NewConversationAsync()
    {
        if (busy) throw new IOException("请先停止当前回复");
        conversation = null; taskId = null; taskKey = null; reply = null; messages.Children.Clear(); RefreshWorkbench(); RenderHistory();
        if (agent?.Connected == true) await RefreshCapabilitiesAsync();
    }
    private async Task SelectAsync(Conversation selected)
    {
        if (busy) throw new IOException("请先停止当前回复");
        conversation = selected; directory.Text = selected.Directory; messages.Children.Clear(); reply = null;
        RefreshWorkbench(); RenderHistory();
        var page = await RequireAgent().CallAsync("history", new { operation = "messages", reference = selected.Reference });
        foreach (var record in page["records"]!.AsArray()) AddMessage("", record?["type"]?.GetValue<string>() == "user").Show(record?["message"]);
        taskKey = LocalState.HostKey(host!) + "|" + selected.SessionId;
        taskId = local.Tasks.GetValueOrDefault(taskKey);
        if (taskId is not null) await WatchCurrentAsync();
        await RefreshCapabilitiesAsync();
    }
    private async Task RefreshCapabilitiesAsync()
    {
        try
        {
            var remote = RequireAgent(); var caps = await remote.CallAsync("task", new { operation = "inspect", digest = remote.Digest, directory = directory.Text, action = "catalogue" });
            availableModels = caps["models"]?.AsArray().Select(m => new ModelChoice(m!["value"]!.GetValue<string>(), m["displayName"]?.GetValue<string>() ?? m["value"]!.GetValue<string>())).ToList() ?? [];
            availableCommands = caps["commands"]?.AsArray().Select(c => c!["name"]!.GetValue<string>()).ToList() ?? [];
        }
        catch (Exception e) { status.Text = "能力读取失败：" + e.Message; }
    }
    private async Task SendAsync()
    {
        if (busy || string.IsNullOrWhiteSpace(prompt.Text)) return;
        if (conversation is not null && directory.Text != conversation.Directory)
            throw new IOException("切换工作目录请新建对话");
        var remote = RequireAgent(); var text = prompt.Text; prompt.Text = ""; busy = true; AddMessage(text, true); reply = AddMessage("正在回复…");
        var message = new { id = Guid.NewGuid().ToString(), role = "assistant", blocks = Array.Empty<object>() };
        try
        {
            if (taskId is null)
            {
                taskId = Guid.NewGuid().ToString(); taskKey = LocalState.HostKey(host!) + "|" + (conversation?.SessionId ?? taskId);
                local.Tasks[taskKey] = taskId; local.Save();
                await remote.CallAsync("task", new { operation = "start", taskId, digest = remote.Digest, request = new { session = new { id = Guid.NewGuid().ToString(), host = host!.Host, directory = directory.Text, name = "Windows 对话", remoteSessionId = conversation?.SessionId, messages = new[] { message }, permissions = Array.Empty<object>(), preferences = new { selectedModel = selectedModel?.Value ?? "" } }, prompt = text } });
                await WatchCurrentAsync();
            }
            else
            {
                await remote.TaskCommandAsync(taskId, new { kind = "control", action = "model", value = selectedModel?.Value ?? "" });
                await remote.TaskCommandAsync(taskId, new { kind = "send", prompt = text, message });
            }
        }
        catch { busy = false; RefreshWorkbench(); status.Text = "发送结果未确认，远端任务可能仍在运行。请重连查看，不要重复发送。"; throw; }
    }
    private Task WatchCurrentAsync()
    {
        var watched = taskId!;
        return RequireAgent().WatchAsync(watched, state => OnState(watched, state));
    }
    private void OnState(string watched, JsonObject state) => DispatcherQueue.TryEnqueue(async () =>
    {
        if (taskId != watched) return; reply ??= AddMessage(""); reply.Show(state["message"]);
        if (state["message"]?["error"] is not null) reply.SetError(state["message"]!["error"]!.GetValue<string>());
        var value = state["status"]?.GetValue<string>(); busy = value is "working" or "connecting" or "permission" or "stopping";
        status.Text = busy ? "正在回复" : "就绪";
        if (state["remoteSessionId"] is JsonValue session && taskId is not null)
        {
            var sessionId = session.GetValue<string>();
            conversation = new Conversation(conversation?.Name ?? "Windows 对话", directory.Text, sessionId, conversation?.Reference);
            local.Tasks[LocalState.HostKey(host!) + "|" + sessionId] = taskId; local.Save();
        }
        if (state["done"]?.GetValue<bool>() == true)
        {
            foreach (var key in local.Tasks.Where(pair => pair.Value == watched).Select(pair => pair.Key).ToList()) local.Tasks.Remove(key);
            local.Save(); taskId = null; busy = false;
        }
        RefreshWorkbench();
        foreach (var permission in state["permissions"]?.AsArray() ?? [])
        {
            var id = permission!["id"]!.GetValue<string>(); if (!approvalDialogs.Add(id)) continue;
            await RunAsync(() => RequestPermissionAsync(watched, permission, id));
        }
    });
    private async Task RequestPermissionAsync(string watched, JsonNode permission, string id)
    {
        await permissionLock.WaitAsync();
        try
        {
            if (taskId != watched) return;
            var fields = new Dictionary<string, TextBox>();
            var panel = new StackPanel { Spacing = 12 };
            var elicitation = permission["kind"]?.GetValue<string>() == "elicitation";
            if (permission["name"]?.GetValue<string>() == "AskUserQuestion")
            {
                foreach (var question in permission["input"]?["questions"]?.AsArray() ?? [])
                {
                    var label = question!["question"]!.GetValue<string>();
                    var field = new TextBox { Header = label, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
                    var options = question["options"]?.AsArray().Select(option => option?["label"]?.GetValue<string>()).ToArray();
                    if (options?.Length > 0) panel.Children.Add(new TextBlock { Text = string.Join(" / ", options), TextWrapping = TextWrapping.Wrap });
                    fields[label] = field; panel.Children.Add(field);
                }
            }
            else panel.Children.Add(new TextBlock { Text = permission.ToJsonString(new() { WriteIndented = true }), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            var dialog = new ContentDialog
            {
                XamlRoot = root.XamlRoot, Title = elicitation ? "此交互暂未支持" : fields.Count > 0 ? "Claude 的问题" : "Claude 请求授权",
                Content = new ScrollViewer { Content = panel, MaxHeight = 400 },
                PrimaryButtonText = elicitation ? "" : fields.Count > 0 ? "提交" : "允许本次", CloseButtonText = "取消"
            };
            dialog.PrimaryButtonClick += (_, e) =>
            {
                if (fields.Values.Any(field => string.IsNullOrWhiteSpace(field.Text))) e.Cancel = true;
            };
            var allow = await dialog.ShowAsync() == ContentDialogResult.Primary;
            if (taskId != watched) return;
            object answer = elicitation ? new { interaction = new { action = "cancel" } } :
                new { allow, answers = fields.ToDictionary(pair => pair.Key, pair => pair.Value.Text) };
            await RequireAgent().TaskCommandAsync(watched, new { kind = "respond", permissionId = id, answer });
        }
        finally { permissionLock.Release(); }
    }
    private async Task StopAsync() { if (taskId is not null) await RequireAgent().TaskCommandAsync(taskId, new { kind = "stop" }); }
    private async Task<string?> PickAsync()
    {
        var picker = new FileOpenPicker(); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this)); picker.FileTypeFilter.Add("*");
        return (await picker.PickSingleFileAsync())?.Path;
    }
    private async Task UploadAsync() { RequireAgent(); var file = await PickAsync(); if (file is not null) await AttachAsync(file); }
    private async Task AttachAsync(string file) { status.Text = "上传中…"; var path = await RequireAgent().UploadAsync(file); prompt.Text += "\n附件：" + path; status.Text = "已上传"; }
    private async Task BrowseAsync()
    {
        var remote = RequireAgent(); var path = new TextBox { Text = directory.Text }; var entries = new StackPanel { Spacing = 4 };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(path); panel.Children.Add(new ScrollViewer { Content = entries, MaxHeight = 400 });
        ContentDialog? browser = null; string? previewPath = null;
        async Task Load()
        {
            var result = await remote.CallAsync("file", new { operation = "list", path = path.Text, @base = directory.Text });
            path.Text = result["path"]!.GetValue<string>(); entries.Children.Clear();
            entries.Children.Add(Button("↑ 上一级", async () => { path.Text = path.Text.TrimEnd('/')[..Math.Max(0, path.Text.TrimEnd('/').LastIndexOf('/'))]; if (path.Text.Length == 0) path.Text = "/"; await Load(); }));
            foreach (var entry in result["entries"]!.AsArray())
            {
                var item = entry!.DeepClone(); entries.Children.Add(Button(item["name"]!.GetValue<string>(), async () =>
                {
                    if (item["directory"]?.GetValue<bool>() == true || item["type"]?.GetValue<string>() == "directory") { path.Text = item["path"]!.GetValue<string>(); await Load(); }
                    else { previewPath = item["path"]!.GetValue<string>(); browser!.Hide(); }
                }));
            }
        }
        panel.Children.Add(Button("前往", Load)); await Load();
        browser = new ContentDialog { XamlRoot = root.XamlRoot, Title = "远端文件", Content = panel, PrimaryButtonText = "设为工作目录", CloseButtonText = "关闭" };
        if (await browser.ShowAsync() == ContentDialogResult.Primary)
        {
            await NewConversationAsync(); directory.Text = path.Text; await RefreshCapabilitiesAsync();
        }
        if (previewPath is not null) await PreviewAsync(previewPath);
    }
    private async Task PreviewAsync(string path)
    {
        var remote = RequireAgent(); var preview = await remote.CallAsync("file", new { operation = "preview", path, @base = directory.Text });
        if (!ReferenceEquals(remote,agent) || host==null) return;
        if ((string?)preview["kind"]=="text") { OpenTextEditor(path,LocalState.HostKey(host),preview);return; }
        UIElement content = new TextBlock { Text = preview["text"]?.GetValue<string>() ?? "此文件请下载后查看", IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        if (preview["kind"]?.GetValue<string>() == "image")
        {
            var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + Path.GetExtension(path)); await remote.DownloadAsync(path, file);
            var bitmap = new BitmapImage(); using (var stream = await Windows.Storage.Streams.RandomAccessStreamReference.CreateFromFile(await Windows.Storage.StorageFile.GetFileFromPathAsync(file)).OpenReadAsync()) { await bitmap.SetSourceAsync(stream); }
            File.Delete(file); content = new Image { Source = bitmap, MaxWidth = 700, MaxHeight = 500 };
        }
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = Path.GetFileName(path), Content = new ScrollViewer { Content = content, MaxHeight = 500 }, PrimaryButtonText = "下载", CloseButtonText = "关闭" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            var picker = new FileSavePicker { SuggestedFileName = Path.GetFileName(path) }; picker.FileTypeChoices.Add("文件", new List<string> { Path.GetExtension(path) is { Length: > 0 } ext ? ext : ".bin" });
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this)); var file = await picker.PickSaveFileAsync(); if (file is not null) await remote.DownloadAsync(path, file.Path);
        }
    }
}
