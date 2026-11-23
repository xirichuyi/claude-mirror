using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private readonly StackPanel queuePanel = new() { Spacing = 4, Visibility = Visibility.Collapsed };

    /// Messages waiting for the current reply to end, above the composer, as on macOS:
    /// each can be sent now, put back in the composer to edit, or removed.
    private void RenderQueue()
    {
        queuePanel.Children.Clear();
        queuePanel.Visibility = queue.Items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (queue.Items.Count == 0) return;
        var rows = new StackPanel { Spacing = 2 };
        var heading = new Grid { ColumnSpacing = 6 };
        heading.ColumnDefinitions.Add(new ColumnDefinition()); heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        heading.Children.Add(new TextBlock
        {
            Text = queue.Paused ? $"已暂停 · {queue.Items.Count} 条" : $"排队 {queue.Items.Count} 条",
            FontSize = 12, Foreground = muted, VerticalAlignment = VerticalAlignment.Center
        });
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        if (queue.Paused)
        {
            var resume = ActionButton("继续发送", "\uE768", async () =>
            {
                queue.Resume();
                if (queue.Next(busy) is { } next) { RenderQueue(); await SendTextAsync(next.Text); }
                else RenderQueue();
            }, true);
            resume.IsEnabled = agent?.Connected == true && !busy;
            controls.Children.Add(resume);
        }
        controls.Children.Add(ActionButton("清空", "\uE74D", () => { queue.Clear(); RenderQueue(); return Task.CompletedTask; }));
        Grid.SetColumn(controls, 1); heading.Children.Add(controls); rows.Children.Add(heading);
        foreach (var item in queue.Items)
        {
            var row = new Grid { ColumnSpacing = 2 };
            row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock
            {
                Text = Presentation.FirstLine(item.Text, 120) ?? "", FontSize = 13, Foreground = ink,
                TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center
            });
            var now = ActionButton("立即发送", "\uE724", () => SteerAsync(item.Id));
            now.IsEnabled = agent?.Connected == true && !stopping;
            var edit = ActionButton("编辑", "\uE70F", () =>
            {
                // The message goes back to the composer; a draft already there is kept after it.
                if (queue.Take(item.Id) is not { } taken) return Task.CompletedTask;
                prompt.Text = string.IsNullOrWhiteSpace(prompt.Text) ? taken.Text : taken.Text + "\n" + prompt.Text;
                prompt.SelectionStart = prompt.Text.Length; prompt.Focus(FocusState.Programmatic);
                RenderQueue(); return Task.CompletedTask;
            });
            var remove = ActionButton("移除", "\uE711", () => { queue.Cancel(item.Id); RenderQueue(); return Task.CompletedTask; });
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Children = { now, edit, remove } };
            Grid.SetColumn(actions, 1); row.Children.Add(actions); rows.Children.Add(row);
        }
        queuePanel.Children.Add(new Border { Child = rows, Background = surface, CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 6, 6, 6) });
    }

    /// Puts the files Claude changed since a message back the way they were: preview what would change, then confirm.
    private async Task RewindAsync(string checkpoint)
    {
        if (busy) throw new IOException("请先停止当前回复");
        if (taskId is null) throw new IOException("这个对话的远端任务已结束，无法回退文件");
        var remote = RequireAgent(); var task = taskId;
        // A control command answers { ok, value }; the preview is the value.
        var preview = (await remote.TaskCommandAsync(task, new { kind = "control", action = "rewind", value = new { checkpoint, preview = true } }))["value"] ?? new JsonObject();
        var changed = (preview["filesChanged"] as JsonArray ?? []).Select(file => Presentation.Text(file)).Where(file => file is not null).ToList();
        bool possible = preview["canRewind"] is JsonValue can && can.TryGetValue<bool>(out var yes) && yes;
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(new TextBlock
        {
            Text = !possible ? Presentation.Text(preview["error"]) ?? "这个检查点没有可回退的文件改动。" : $"将把 {changed.Count} 个文件恢复到这条回复之前的内容。对话记录不会改变。",
            TextWrapping = TextWrapping.Wrap
        });
        foreach (var file in changed.Take(50)) panel.Children.Add(new TextBlock { Text = file, FontFamily = Mono, FontSize = 12, Foreground = muted, TextTrimming = TextTrimming.CharacterEllipsis });
        if (changed.Count > 50) panel.Children.Add(new TextBlock { Text = $"还有 {changed.Count - 50} 个文件", FontSize = 12, Foreground = muted });
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot, Title = "回退文件改动", Content = new ScrollViewer { Content = panel, MaxHeight = 360 },
            PrimaryButtonText = possible ? "回退" : "", CloseButtonText = possible ? "取消" : "关闭", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await remote.TaskCommandAsync(task, new { kind = "control", action = "rewind", value = new { checkpoint, token = Presentation.Text(preview["token"]) } });
        status.Text = $"已回退 {changed.Count} 个文件";
    }

    private readonly StackPanel permissionPanel = new() { Spacing = 8 };
    private readonly Dictionary<string, FrameworkElement> permissionCards = [];

    /// Requests waiting for an answer sit above the composer. A card stays as it is while its request is pending, so typed answers are not lost on the next state update.
    private void RenderPermissions(string? task, JsonArray? pending)
    {
        var ids = (pending ?? []).Select(permission => Presentation.Text(permission?["id"])).Where(id => id is not null).ToHashSet();
        foreach (var gone in permissionCards.Keys.Where(id => !ids.Contains(id)).ToList())
        {
            permissionPanel.Children.Remove(permissionCards[gone]); permissionCards.Remove(gone);
        }
        foreach (var permission in pending ?? [])
        {
            if (Presentation.Text(permission?["id"]) is not { } id || permissionCards.ContainsKey(id) || task is null) continue;
            var card = PermissionCard(task, id, permission!);
            permissionCards[id] = card; permissionPanel.Children.Add(card);
        }
        permissionPanel.Visibility = permissionCards.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private FrameworkElement PermissionCard(string task, string id, JsonNode permission)
    {
        var name = Presentation.Text(permission["name"]);
        bool elicitation = Presentation.Text(permission["kind"]) == "elicitation", asking = name == "AskUserQuestion", plan = name == "ExitPlanMode";
        var panel = new StackPanel { Spacing = 10 };
        var waiting = Row(new FontIcon { Glyph = "\uE946", FontSize = 12, Foreground = accent }, new TextBlock { Text = "等待你的确认", FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = accent });
        waiting.Spacing = 6; panel.Children.Add(waiting);
        panel.Children.Add(new TextBlock
        {
            Text = PermissionText.Title(permission),
            FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ink, TextWrapping = TextWrapping.Wrap
        });
        if (Presentation.Text(permission["description"]) is { Length: > 0 } description)
            panel.Children.Add(new TextBlock { Text = description, FontSize = 13, Foreground = muted, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        var failure = new TextBlock { FontSize = 12, Foreground = danger, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        async Task Answer(object answer)
        {
            try
            {
                foreach (var button in buttons.Children.OfType<Button>()) button.IsEnabled = false;
                await RequireAgent().TaskCommandAsync(task, new { kind = "respond", permissionId = id, answer });
            }
            catch (Exception e)
            {
                foreach (var button in buttons.Children.OfType<Button>()) button.IsEnabled = true;
                failure.Text = e.Message; failure.Visibility = Visibility.Visible;
            }
        }
        Button Choice(string label, bool primary, Func<Task> action)
        {
            var button = Button(label, action); button.CornerRadius = new CornerRadius(8); button.Padding = new Thickness(14, 6, 14, 6);
            if (primary) Primary(button);
            buttons.Children.Add(button); return button;
        }
        if (elicitation)
        {
            var request = permission["request"];
            if (Presentation.Text(request?["message"]) is { } message) panel.Children.Add(new TextBlock { Text = message, FontSize = 13, Foreground = ink, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            bool link = Presentation.Text(request?["mode"]) == "url" && Uri.TryCreate(Presentation.Text(request?["url"]), UriKind.Absolute, out var url) && url.Scheme is "http" or "https";
            if (link) panel.Children.Add(new HyperlinkButton { Content = "打开 " + Presentation.Text(request?["url"]), NavigateUri = new Uri(Presentation.Text(request!["url"])!), Padding = new Thickness(0) });
            else panel.Children.Add(new TextBlock { Text = "Windows 版暂不支持填写这种表单，可以取消或拒绝。", FontSize = 12, Foreground = muted, TextWrapping = TextWrapping.Wrap });
            Choice("取消", false, () => Answer(new { interaction = new { action = "cancel" } }));
            Choice("拒绝", false, () => Answer(new { interaction = new { action = "decline" } }));
            if (link) Choice("已完成，继续", true, () => Answer(new { interaction = new { action = "accept" } }));
        }
        else
        {
            var answers = new List<(string Question, List<string> Picked, TextBox Typed)>();
            if (asking)
                foreach (var question in permission["input"]?["questions"] as JsonArray ?? [])
                {
                    if (Presentation.Text(question?["question"]) is not { } label) continue;
                    bool multiple = question!["multiSelect"] is JsonValue multi && multi.TryGetValue<bool>(out var many) && many;
                    panel.Children.Add(new TextBlock { Text = label + (multiple ? "（可多选）" : ""), FontSize = 13, Foreground = ink, TextWrapping = TextWrapping.Wrap });
                    var picked = new List<string>();
                    var group = id + "-" + answers.Count;
                    foreach (var option in question["options"] as JsonArray ?? [])
                    {
                        if (Presentation.Text(option?["label"]) is not { } choice) continue;
                        var text = new StackPanel();
                        text.Children.Add(new TextBlock { Text = choice, FontSize = 13, Foreground = ink, TextWrapping = TextWrapping.Wrap });
                        if (Presentation.Text(option!["description"]) is { Length: > 0 } hint) text.Children.Add(new TextBlock { Text = hint, FontSize = 12, Foreground = muted, TextWrapping = TextWrapping.Wrap });
                        // The label is kept whole, so an option containing a comma stays one answer.
                        Microsoft.UI.Xaml.Controls.Primitives.ToggleButton pick = multiple ? new CheckBox { Content = text } : new RadioButton { Content = text, GroupName = group };
                        pick.Checked += (_, _) => { if (!multiple) picked.Clear(); if (!picked.Contains(choice)) picked.Add(choice); };
                        pick.Unchecked += (_, _) => picked.Remove(choice);
                        panel.Children.Add(pick);
                    }
                    var typed = new TextBox { PlaceholderText = "或者直接写下你的回答", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
                    answers.Add((label, picked, typed)); panel.Children.Add(typed);
                }
            else
            {
                var tool = new ToolPresentation(name, permission["input"]);
                if (tool.File is { } file) panel.Children.Add(new TextBlock { Text = file, FontFamily = Mono, FontSize = 12, Foreground = muted, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                switch (tool.Body)
                {
                    case ToolBodyKind.Command: panel.Children.Add(CodePanel(tool.Text, "bash", false, "命令")); break;
                    case ToolBodyKind.Code: panel.Children.Add(CodePanel(tool.Text, Path.GetExtension(tool.File ?? "").TrimStart('.'), false, tool.File is null ? "内容" : null)); break;
                    case ToolBodyKind.Diff: panel.Children.Add(DiffPanel(tool.Diff)); break;
                    case ToolBodyKind.Markdown: panel.Children.Add(MarkdownView(tool.Text)); break;
                    default: if (tool.Subject is { } subject) panel.Children.Add(new TextBlock { Text = subject, FontSize = 13, Foreground = ink, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }); break;
                }
            }
            CheckBox? rules = null;
            var lines = asking ? [] : PermissionText.RuleLines(permission["suggestions"]);
            if (lines.Count > 0)
            {
                rules = new CheckBox { Content = "以后同类操作不再询问", FontSize = 12 };
                panel.Children.Add(rules);
                foreach (var line in lines)
                    panel.Children.Add(new TextBlock { Text = (line.Widens ? "⚠ " : "") + line.Action + " · " + line.Scope, FontSize = 12, Foreground = muted, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(28, -6, 0, 0) });
            }
            var reason = new TextBox { PlaceholderText = plan ? "对计划的修改意见（选“拒绝”时发给 Claude）" : "补充说明（可选，拒绝时发给 Claude）", FontSize = 13 };
            if (!asking) panel.Children.Add(reason);
            var allowText = asking ? "提交回答" : plan ? "开始执行" : "允许这一次";
            Choice("拒绝", false, () => Answer(new { allow = false, reason = reason.Text }));
            var allow = Choice(allowText, true, () =>
            {
                if (answers.Any(answer => PermissionText.Answer(answer.Picked, answer.Typed.Text).Length == 0)) { failure.Text = "每个问题都需要回答"; failure.Visibility = Visibility.Visible; return Task.CompletedTask; }
                // `answers` is merged into the tool's input on the server, so only a question gets it.
                var answer = new JsonObject { ["allow"] = true, ["useSuggestedPermissions"] = rules?.IsChecked == true };
                if (asking) answer["answers"] = new JsonObject(answers.Select(item => KeyValuePair.Create(item.Question, (JsonNode?)PermissionText.Answer(item.Picked, item.Typed.Text))));
                return Answer(answer);
            });
            if (rules is not null)
            {
                rules.Checked += (_, _) => allow.Content = "允许并记住";
                rules.Unchecked += (_, _) => allow.Content = allowText;
            }
        }
        panel.Children.Add(failure); panel.Children.Add(buttons);
        return new Border
        {
            Child = new ScrollViewer { Content = panel, MaxHeight = 420, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 8, 0) },
            Background = canvas, BorderBrush = accent, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 12, 6, 12)
        };
    }

    private string permissionMode = "default";
    /// The server account Claude runs as when SSH logs in as root; empty means the SSH user.
    private string executionUser = "";
    private bool AutoModeSupported => selectedModel is null || selectedModel.Auto;
    private Button permissionMenu = null!;

    /// The permission mode for this conversation; a change reaches a running task at once.
    private Button PermissionPicker()
    {
        permissionMenu = ActionButton("权限模式", "\uE72E", () => Task.CompletedTask, true);
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            foreach (var mode in PermissionModes.For(AutoModeSupported || permissionMode == "auto"))
            {
                var choice = new ToggleMenuFlyoutItem { Text = mode.Label + " · " + mode.Hint, IsChecked = mode.Value == permissionMode };
                choice.Click += async (_, _) => await RunAsync(() => SetPermissionModeAsync(mode.Value));
                menu.Items.Add(choice);
            }
        };
        permissionMenu.Flyout = menu; UpdatePermissionTitle();
        return permissionMenu;
    }
    private async Task SetPermissionModeAsync(string mode)
    {
        var account = executionUser;
        if (mode == PermissionModes.FullAccess && permissionMode != mode)
        {
            if (await AskFullAccessAsync() is not { } chosen) return;
            account = chosen;
        }
        if (taskId is not null && agent?.Connected == true)
            await agent.TaskCommandAsync(taskId, new { kind = "control", action = "permission", value = mode });
        permissionMode = mode; executionUser = account; UpdatePermissionTitle();
    }
    /// Explains Full Access, asks the server whether this login may use it, and returns the account to run as; null when the user backs out.
    private async Task<string?> AskFullAccessAsync()
    {
        var remote = RequireAgent();
        bool started = taskId is not null || conversation?.SessionId is not null;
        var current = FullAccessStatus.From(await remote.CallAsync("task", new { operation = "inspect", digest = remote.Digest, directory = directory.Text, action = "permissionStatus", preferences = new { executionUser } }));
        var panel = new StackPanel { Spacing = 10, MaxWidth = 420 };
        panel.Children.Add(new TextBlock { Text = "Full Access 会跳过 Claude 的操作确认：它可以直接修改文件和执行命令，只受执行账号的系统权限限制。", TextWrapping = TextWrapping.Wrap });
        var account = new TextBox { Header = "Claude 执行账号", PlaceholderText = "例如 claude-runner", Text = executionUser, IsEnabled = !started };
        var problem = new TextBlock { Foreground = danger, FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        if (current.NeedsAccount || executionUser.Length > 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = started
                    ? "这个对话以 root 运行，Claude 不允许 root 使用 Full Access。请新建对话，再选择一个普通执行账号。"
                    : "SSH 登录的是 root，Claude 不允许 root 使用 Full Access。请填写服务器上已配置好的普通账号；它使用独立的登录和历史记录。",
                TextWrapping = TextWrapping.Wrap, Foreground = muted, FontSize = 12
            });
            panel.Children.Add(account);
        }
        panel.Children.Add(problem);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "开启 Full Access？", Content = panel, PrimaryButtonText = "开启", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
        string? result = null;
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var wait = e.GetDeferral();
            try
            {
                var name = PermissionModes.ExecutionAccount(account.Text, started, executionUser);
                // The server resolves the account and refuses root, a missing account, or one that cannot use this project.
                var status = FullAccessStatus.From(await remote.CallAsync("task", new { operation = "inspect", digest = remote.Digest, directory = directory.Text, action = "permissionStatus", preferences = new { permissionMode = PermissionModes.FullAccess, executionUser = name } }));
                if (!status.Available) throw new IOException("这个账号不能使用 Full Access");
                result = name;
            }
            catch (Exception error) { e.Cancel = true; problem.Text = error.Message; problem.Visibility = Visibility.Visible; }
            finally { wait.Complete(); }
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? result : null;
    }
    /// Another conversation runs as its own account, and Full Access is granted to one conversation at a time.
    private void UseAccount(string? account)
    {
        executionUser = account ?? "";
        if (permissionMode == PermissionModes.FullAccess) { permissionMode = "default"; UpdatePermissionTitle(); }
    }
    private void UpdatePermissionTitle()
    {
        var label = PermissionModes.Label(permissionMode);
        permissionMenu.Content = new TextBlock { Text = label, FontSize = 12 }; permissionMenu.Foreground = muted;
    }
}
