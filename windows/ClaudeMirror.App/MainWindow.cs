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

public sealed class MainWindow : Window
{
    private readonly Grid root = new();
    private readonly StackPanel sidebar = new() { Spacing = 12, Padding = new Thickness(16) };
    private readonly StackPanel projects = new() { Spacing = 8 };
    private readonly StackPanel messages = new() { Spacing = 18, Padding = new Thickness(24) };
    private readonly ScrollViewer scroll;
    private readonly TextBox prompt = new() { PlaceholderText = "发送消息，或输入 / 使用命令", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90, MaxHeight = 220 };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    private readonly ComboBox hosts = new() { PlaceholderText = "选择主机", HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Name" };
    private readonly ComboBox models = new() { PlaceholderText = "远端默认", MinWidth = 160, DisplayMemberPath = "Label" };
    private readonly ComboBox commands = new() { PlaceholderText = "命令", MinWidth = 100 };
    private readonly LocalState local = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "claude-mirror"));
    private readonly TextBox directory = new() { Text = "~", PlaceholderText = "远端工作目录" };
    private RemoteAgent? agent;
    private HostProfile? host;
    private Conversation? conversation;
    private string? taskId;
    private string? taskKey;
    private bool busy;
    private TextBlock? reply;
    private readonly SemaphoreSlim permissionLock = new(1);
    private readonly HashSet<string> approvalDialogs = [];
    private sealed record ModelChoice(string Value, string Label);
    private static SolidColorBrush Brush(byte r, byte g, byte b) => new(Windows.UI.Color.FromArgb(255, r, g, b));

    public MainWindow()
    {
        Title = "claude-mirror · Windows";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 820));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        root.Background = Brush(250, 246, 242); root.RequestedTheme = ElementTheme.Light;
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260) });
        root.ColumnDefinitions.Add(new ColumnDefinition());
        sidebar.Background = Brush(240, 234, 227);
        sidebar.Children.Add(new Image { Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "BrandIcon.png"))), Width = 48, Height = 48, HorizontalAlignment = HorizontalAlignment.Left });
        sidebar.Children.Add(new TextBlock { Text = "claude-mirror", FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        hosts.ItemsSource = local.Hosts; sidebar.Children.Add(hosts);
        sidebar.Children.Add(Row(Button("连接", () => ConnectDialogAsync(hosts.SelectedItem as HostProfile)), Button("添加主机", () => ConnectDialogAsync(null))));
        sidebar.Children.Add(Row(Button("新建对话", NewConversationAsync), Button("↻", RefreshHistoryAsync)));
        sidebar.Children.Add(new ScrollViewer { Content = projects, MaxHeight = 440 });
        sidebar.Children.Add(status);
        root.Children.Add(sidebar);
        var chat = new Grid { Padding = new Thickness(20) }; Grid.SetColumn(chat, 1);
        chat.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        chat.RowDefinitions.Add(new RowDefinition()); chat.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = Row(directory, Button("文件", BrowseAsync), Button("更新", () => Windows.System.Launcher.LaunchUriAsync(new Uri("https://github.com/xirichuyi/claude-mirror/releases")).AsTask()));
        chat.Children.Add(header);
        scroll = new ScrollViewer { Content = messages }; Grid.SetRow(scroll, 1); chat.Children.Add(scroll);
        var composer = new StackPanel { Spacing = 10 };
        composer.Children.Add(prompt);
        composer.Children.Add(Row(Button("附件", UploadAsync), commands, models, Button("停止", StopAsync), Button("发送", SendAsync)));
        Grid.SetRow(composer, 2); chat.Children.Add(composer); root.Children.Add(chat); Content = root;
        prompt.AllowDrop = true;
        prompt.DragOver += (_, e) => { if (e.DataView.Contains(StandardDataFormats.StorageItems)) e.AcceptedOperation = DataPackageOperation.Copy; };
        prompt.Drop += async (_, e) => await RunAsync(async () => { foreach (var file in await e.DataView.GetStorageItemsAsync()) if (file is Windows.Storage.StorageFile) await AttachAsync(file.Path); });
        commands.SelectionChanged += (_, _) => { if (commands.SelectedItem is string name) { prompt.Text = "/" + name + " "; prompt.Focus(FocusState.Programmatic); commands.SelectedIndex = -1; } };
        Closed += (_, _) => agent?.Dispose();
        status.Text = "连接 SSH 服务器开始使用";
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
        var name = new TextBox { Header = "主机名称", Text = existing?.Name ?? "" };
        var address = new TextBox { Header = "地址", Text = existing?.Host ?? "" };
        var user = new TextBox { Header = "用户名", Text = existing?.User ?? "" };
        var port = new NumberBox { Header = "端口", Value = existing?.Port ?? 22, Minimum = 1, Maximum = 65535 };
        var mode = new ComboBox { Header = "认证", ItemsSource = new[] { "密码", "私钥" }, SelectedIndex = existing?.KeyFile is null ? 0 : 1 };
        var password = new PasswordBox { Header = "密码" }; var phrase = new PasswordBox { Header = "私钥口令（可选）" };
        var key = new TextBox { Header = "私钥文件", Text = existing?.KeyFile ?? "" };
        var pick = Button("选择私钥", async () => { var file = await PickAsync(); if (file is not null) key.Text = file; });
        void UpdateMode() { password.Visibility = mode.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed; phrase.Visibility = key.Visibility = pick.Visibility = mode.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed; }
        mode.SelectionChanged += (_, _) => UpdateMode(); UpdateMode();
        var panel = new StackPanel { Spacing = 10 }; foreach (var element in new UIElement[] { name, address, user, port, mode, password, key, pick, phrase }) panel.Children.Add(element);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "连接服务器", Content = new ScrollViewer { Content = panel }, PrimaryButtonText = "连接", CloseButtonText = "取消" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var profile = new HostProfile(string.IsNullOrWhiteSpace(name.Text) ? address.Text.Trim() : name.Text.Trim(), address.Text.Trim(), (int)port.Value, user.Text.Trim(), mode.SelectedIndex == 1 ? key.Text : null);
        agent?.Dispose(); var next = new RemoteAgent(); agent = next; status.Text = "正在连接…";
        next.Disconnected += error => DispatcherQueue.TryEnqueue(() => { if (agent == next) { status.Text = error; busy = false; } });
        try { await next.ConnectAsync(profile, password.Password, phrase.Password, Path.Combine(AppContext.BaseDirectory, "server"), fingerprint => ConfirmHostAsync(profile, fingerprint)); }
        catch { next.Dispose(); throw; }
        finally { password.Password = ""; phrase.Password = ""; }
        busy = false; host = profile; local.Hosts.RemoveAll(h => LocalState.HostKey(h) == LocalState.HostKey(profile)); local.Hosts.Add(profile); local.Save();
        hosts.ItemsSource = local.Hosts.ToList(); hosts.SelectedItem = profile; directory.Text = next.Home;
        await NewConversationAsync(); await RefreshHistoryAsync(); status.Text = "已连接";
    }
    private RemoteAgent RequireAgent() => agent?.Connected == true ? agent : throw new IOException("请先连接服务器");
    private async Task RefreshHistoryAsync()
    {
        var remote = RequireAgent(); var sessions = new List<Conversation>(); object offset = 0;
        do
        {
            var page = await remote.CallAsync("history", new { operation = "list", offset });
            foreach (var item in page["sessions"]!.AsArray()) sessions.Add(new(item!["name"]!.GetValue<string>(), item["directory"]?.GetValue<string>() ?? remote.Home, item["sessionId"]?.GetValue<string>(), item["reference"]?.GetValue<string>()));
            if (page["nextOffset"] is null) break; offset = page["nextOffset"]!.GetValue<string>();
        } while (true);
        projects.Children.Clear();
        foreach (var group in sessions.GroupBy(c => c.Directory))
        {
            var rows = new StackPanel { Spacing = 4 };
            rows.Children.Add(Button("＋ 新建对话", async () => { directory.Text = group.Key; await NewConversationAsync(); }));
            foreach (var session in group) rows.Children.Add(Button(session.Name.Length > 26 ? session.Name[..26] + "…" : session.Name, () => SelectAsync(session)));
            projects.Children.Add(new Expander { Header = group.Key.Split('/').LastOrDefault() ?? group.Key, Content = rows, HorizontalAlignment = HorizontalAlignment.Stretch });
        }
        status.Text = $"已同步 {sessions.Count} 条会话";
    }
    private async Task NewConversationAsync()
    {
        if (busy) throw new IOException("请先停止当前回复");
        conversation = null; taskId = null; taskKey = null; reply = null; messages.Children.Clear();
        if (agent?.Connected == true) await RefreshCapabilitiesAsync();
    }
    private async Task SelectAsync(Conversation selected)
    {
        if (busy) throw new IOException("请先停止当前回复");
        conversation = selected; directory.Text = selected.Directory; messages.Children.Clear(); reply = null;
        var page = await RequireAgent().CallAsync("history", new { operation = "messages", reference = selected.Reference });
        foreach (var record in page["records"]!.AsArray()) AddMessage(Protocol.MessageText(record?["message"]), record?["type"]?.GetValue<string>() == "user");
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
            models.ItemsSource = caps["models"]?.AsArray().Select(m => new ModelChoice(m!["value"]!.GetValue<string>(), m["displayName"]?.GetValue<string>() ?? m["value"]!.GetValue<string>())).ToList();
            commands.ItemsSource = caps["commands"]?.AsArray().Select(c => c!["name"]!.GetValue<string>()).ToList();
        }
        catch (Exception e) { status.Text = "能力读取失败：" + e.Message; }
    }
    private TextBlock AddMessage(string text, bool user = false)
    {
        var block = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 15 };
        messages.Children.Add(new Border { Child = block, Padding = new Thickness(14), CornerRadius = new CornerRadius(14), Background = user ? Brush(237, 229, 220) : Brush(250, 246, 242), HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Stretch });
        return block;
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
                await remote.CallAsync("task", new { operation = "start", taskId, digest = remote.Digest, request = new { session = new { id = Guid.NewGuid().ToString(), host = host!.Host, directory = directory.Text, name = "Windows 对话", remoteSessionId = conversation?.SessionId, messages = new[] { message }, permissions = Array.Empty<object>(), preferences = new { selectedModel = (models.SelectedItem as ModelChoice)?.Value ?? "" } }, prompt = text } });
                await WatchCurrentAsync();
            }
            else
            {
                await remote.TaskCommandAsync(taskId, new { kind = "control", action = "model", value = (models.SelectedItem as ModelChoice)?.Value ?? "" });
                await remote.TaskCommandAsync(taskId, new { kind = "send", prompt = text, message });
            }
        }
        catch { busy = false; status.Text = "发送结果未确认，远端任务可能仍在运行。请重连查看，不要重复发送。"; throw; }
    }
    private Task WatchCurrentAsync()
    {
        var watched = taskId!;
        return RequireAgent().WatchAsync(watched, state => OnState(watched, state));
    }
    private void OnState(string watched, JsonObject state) => DispatcherQueue.TryEnqueue(async () =>
    {
        if (taskId != watched) return; reply ??= AddMessage(""); reply.Text = Protocol.MessageText(state["message"]);
        if (state["message"]?["error"] is not null) reply.Text += "\n" + state["message"]!["error"]!.GetValue<string>();
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
