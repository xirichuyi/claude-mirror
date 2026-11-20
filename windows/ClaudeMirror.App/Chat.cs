using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private readonly StackPanel queuePanel = new() { Spacing = 4, Visibility = Visibility.Collapsed };

    /// Messages waiting for the current reply to end, above the composer; each can be withdrawn.
    private void RenderQueue()
    {
        queuePanel.Children.Clear();
        queuePanel.Visibility = queue.Items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (queue.Items.Count == 0) return;
        var heading = new Grid();
        heading.Children.Add(new TextBlock { Text = queue.Paused ? $"队列已暂停（{queue.Items.Count} 条）" : $"回复结束后发送（{queue.Items.Count} 条）", FontSize = 12, Foreground = muted, VerticalAlignment = VerticalAlignment.Center });
        if (queue.Paused)
        {
            var resume = ActionButton("继续发送", "\uE768", async () =>
            {
                queue.Resume();
                if (queue.Next(busy) is { } next) { RenderQueue(); await SendTextAsync(next.Text); } else RenderQueue();
            }, true);
            resume.HorizontalAlignment = HorizontalAlignment.Right; heading.Children.Add(resume);
        }
        queuePanel.Children.Add(heading);
        foreach (var item in queue.Items)
        {
            var row = new Grid { ColumnSpacing = 6 };
            row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = Presentation.FirstLine(item.Text, 120) ?? "", FontSize = 13, Foreground = ink, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center });
            var cancel = ActionButton("取消这条消息", "\uE711", () => { queue.Cancel(item.Id); RenderQueue(); return Task.CompletedTask; });
            Grid.SetColumn(cancel, 1); row.Children.Add(cancel);
            queuePanel.Children.Add(new Border { Child = row, Background = surface, BorderBrush = edge, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 2, 4, 2) });
        }
    }

    /// Puts the files Claude changed since a message back the way they were: preview what would change, then confirm.
    private async Task RewindAsync(string checkpoint)
    {
        if (busy) throw new IOException("请先停止当前回复");
        if (taskId is null) throw new IOException("这个对话的远端任务已结束，无法回退文件");
        var remote = RequireAgent(); var task = taskId;
        var preview = await remote.TaskCommandAsync(task, new { kind = "control", action = "rewind", value = new { checkpoint, preview = true } });
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
    private static readonly Dictionary<string, string> RuleScopes = new()
    {
        ["session"] = "本次运行", ["localSettings"] = "此项目的本地设置", ["projectSettings"] = "此项目的共享设置", ["userSettings"] = "远端用户的所有项目", ["cliArg"] = "本次启动参数"
    };

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
        bool elicitation = Presentation.Text(permission["kind"]) == "elicitation", asking = name == "AskUserQuestion";
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock
        {
            Text = Presentation.Text(permission["title"]) ?? (asking ? "Claude 的问题" : elicitation ? "需要你的输入" : $"Claude 请求使用 {name}"),
            FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ink, TextWrapping = TextWrapping.Wrap
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
            if (primary) { button.Background = ink; button.Foreground = canvas; }
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
            var answers = new Dictionary<string, TextBox>();
            if (asking)
                foreach (var question in permission["input"]?["questions"] as JsonArray ?? [])
                {
                    if (Presentation.Text(question?["question"]) is not { } label) continue;
                    bool multiple = question!["multiSelect"] is JsonValue multi && multi.TryGetValue<bool>(out var many) && many;
                    var field = new TextBox { PlaceholderText = "输入你的回答，也可以选择上面的选项", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
                    panel.Children.Add(new TextBlock { Text = label, FontSize = 13, Foreground = ink, TextWrapping = TextWrapping.Wrap });
                    foreach (var option in question["options"] as JsonArray ?? [])
                    {
                        if (Presentation.Text(option?["label"]) is not { } choice) continue;
                        var pick = new Button { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 6, 10, 6) };
                        var text = new StackPanel();
                        text.Children.Add(new TextBlock { Text = choice, FontSize = 13, Foreground = ink, TextWrapping = TextWrapping.Wrap });
                        if (Presentation.Text(option!["description"]) is { Length: > 0 } hint) text.Children.Add(new TextBlock { Text = hint, FontSize = 12, Foreground = muted, TextWrapping = TextWrapping.Wrap });
                        pick.Content = text;
                        pick.Click += (_, _) =>
                        {
                            if (!multiple) { field.Text = choice; return; }
                            var chosen = field.Text.Split(", ", StringSplitOptions.RemoveEmptyEntries).ToList();
                            if (!chosen.Remove(choice)) chosen.Add(choice);
                            field.Text = string.Join(", ", chosen);
                        };
                        panel.Children.Add(pick);
                    }
                    answers[label] = field; panel.Children.Add(field);
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
            if (permission["suggestions"] is JsonArray { Count: > 0 } suggestions)
            {
                var scopes = suggestions.Select(rule => Presentation.Text(rule?["destination"])).Where(scope => scope is not null).Select(scope => RuleScopes.GetValueOrDefault(scope!, scope!)).Distinct();
                rules = new CheckBox { Content = "以后不再询问同类操作 · " + string.Join("、", scopes), FontSize = 12 };
                ToolTipService.SetToolTip(rules, suggestions.ToJsonString(new() { WriteIndented = true }));
                panel.Children.Add(rules);
            }
            var reason = new TextBox { PlaceholderText = "拒绝时可以告诉 Claude 该怎么改（可选）", FontSize = 13 };
            if (!asking) panel.Children.Add(reason);
            Choice(asking ? "跳过" : "拒绝", false, () => Answer(new { allow = false, reason = reason.Text }));
            Choice(asking ? "提交" : "允许", true, () =>
            {
                if (answers.Values.Any(field => string.IsNullOrWhiteSpace(field.Text))) { failure.Text = "请先回答每个问题"; failure.Visibility = Visibility.Visible; return Task.CompletedTask; }
                // `answers` is merged into the tool's input on the server, so only a question gets it.
                var answer = new JsonObject { ["allow"] = true, ["useSuggestedPermissions"] = rules?.IsChecked == true };
                if (asking) answer["answers"] = new JsonObject(answers.Select(pair => KeyValuePair.Create(pair.Key, (JsonNode?)pair.Value.Text)));
                return Answer(answer);
            });
        }
        panel.Children.Add(failure); panel.Children.Add(buttons);
        return new Border
        {
            Child = new ScrollViewer { Content = panel, MaxHeight = 420, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 8, 0) },
            Background = surface, BorderBrush = amber, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(14, 12, 6, 12)
        };
    }
}
