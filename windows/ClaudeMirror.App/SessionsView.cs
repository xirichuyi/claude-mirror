using ClaudeMirror.Core;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ClaudeMirror.App;

public sealed partial class MainWindow
{
    private MenuFlyoutItem MenuItem(string text, string glyph, Func<Task> action)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += async (_, _) => await RunAsync(action);
        return item;
    }

    /// One conversation in the sidebar. Right-click (or the menu key) offers rename, pin, archive, details and removal.
    private Button ConversationRow(Sessions.Entry entry, string? glyph)
    {
        var c = entry.Conversation;
        var row = Flat(Button(c.Name, () => SelectAsync(c)));
        var name = new TextBlock { Text = c.Name, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis };
        // A conversation going on in the background says so under its name.
        FrameworkElement title = name;
        if (!IsCurrent(c) && ParkedFor(c) is { Label: { } label } waiting)
        {
            var lines = new StackPanel(); lines.Children.Add(name);
            lines.Children.Add(new TextBlock { Text = label, FontSize = 11, Foreground = waiting.Busy && Turn.NeedsAnswer(waiting.State) ? amber : sage });
            title = lines;
        }
        title.VerticalAlignment = VerticalAlignment.Center;
        var content = Row(RowIcon(glyph ?? "\uE8BD"), title); content.Spacing = 6; row.Content = content;
        row.HorizontalAlignment = HorizontalAlignment.Stretch; row.HorizontalContentAlignment = HorizontalAlignment.Left;
        row.Padding = new Thickness(8, 5, 8, 5);
        if (IsCurrent(c)) { row.Background = selected; row.Resources["ButtonBackgroundPointerOver"] = selected; row.Resources["ButtonBackgroundPressed"] = selected; }
        ToolTipService.SetToolTip(row, c.Name);
        var menu = new MenuFlyout();
        menu.Items.Add(MenuItem("重命名…", "\uE8AC", () => RenameAsync(entry)));
        if (!entry.Archived) menu.Items.Add(MenuItem(entry.Pinned ? "取消固定" : "固定", entry.Pinned ? "\uE77A" : "\uE718", () => Mark(() => Sessions.SetPinned(local, entry.Key, !entry.Pinned))));
        menu.Items.Add(MenuItem(entry.Archived ? "取消归档" : "归档", "\uE7B8", () =>
        {
            if (!entry.Archived && Active(c)) throw new IOException("请先完成或取消此会话中的任务");
            return Mark(() => Sessions.SetArchived(local, entry.Key, !entry.Archived));
        }));
        menu.Items.Add(MenuItem("详情", "\uE946", () => DetailsAsync(entry)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("从列表移除…", "\uE74D", () => RemoveAsync(entry)));
        row.ContextFlyout = menu;
        return row;
    }

    private Task Mark(Action change) { change(); local.Save(); RenderHistory(); return Task.CompletedTask; }

    private async Task RenameAsync(Sessions.Entry entry)
    {
        var field = new TextBox { Text = entry.Conversation.Name, MaxLength = 80, SelectionStart = 0, SelectionLength = entry.Conversation.Name.Length };
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "重命名对话", Content = field, PrimaryButtonText = "保存", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Primary };
        dialog.PrimaryButtonClick += (_, e) => e.Cancel = string.IsNullOrWhiteSpace(field.Text);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var name = Sessions.Rename(local, entry.Key, field.Text); local.Save();
        if (IsCurrent(entry.Conversation)) conversation = conversation! with { Name = name };
        RenderHistory(); RefreshWorkbench();
    }

    private async Task DetailsAsync(Sessions.Entry entry)
    {
        var c = entry.Conversation; var panel = new StackPanel { Spacing = 10, MinWidth = 380 };
        void Line(string label, string? value)
        {
            if (string.IsNullOrEmpty(value)) return;
            panel.Children.Add(new TextBlock { Text = label, FontSize = 12, Foreground = muted });
            panel.Children.Add(new TextBlock { Text = value, FontSize = 13, Foreground = ink, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Margin = new Thickness(0, -6, 0, 0) });
        }
        Line("名称", c.Name);
        Line("服务器", host is null ? null : $"{host.Name}（{LocalState.HostKey(host)}）");
        Line("工作目录", c.Directory);
        Line("会话 ID", c.SessionId);
        Line("远端任务", local.Tasks.GetValueOrDefault(entry.Key) is { } task ? task + ((IsCurrent(c) ? busy : ParkedFor(c)?.Busy == true) ? "（正在回复）" : "") : "没有保留的任务，继续对话时会重新启动");
        Line("状态", string.Join("、", new[] { entry.Pinned ? "已固定" : null, entry.Archived ? "已归档" : null, local.Names.ContainsKey(entry.Key) ? "已在本机重命名" : null }.Where(mark => mark is not null)));
        Line("继续此对话的命令", c.SessionId is null ? null : $"cd {Protocol.Quote(c.Directory)} && claude --resume {c.SessionId}");
        await new ContentDialog { XamlRoot = root.XamlRoot, Title = "对话详情", Content = new ScrollViewer { Content = panel, MaxHeight = 420 }, CloseButtonText = "关闭" }.ShowAsync();
    }

    private async Task RemoveAsync(Sessions.Entry entry)
    {
        if (IsCurrent(entry.Conversation) && busy) throw new IOException("请先停止当前回复，再移除对话");
        if (!IsCurrent(entry.Conversation) && ParkedFor(entry.Conversation)?.Active == true) throw new IOException("这个对话还在后台回复或有排队的消息，请先打开它并停止");
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot, Title = "从列表移除对话",
            Content = new TextBlock { Text = $"“{entry.Conversation.Name}”将不再显示在这台电脑的列表里。服务器上的对话记录不会删除。", TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = "移除", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        bool current = IsCurrent(entry.Conversation);
        if (current) await ConfirmLeavingQueueAsync(); // Declining keeps the conversation, so nothing is hidden yet.
        Sessions.Hide(local, entry.Key); local.Save();
        if (!current && ParkedFor(entry.Conversation) is { } idle) await ForgetParkedAsync(idle);
        if (current) { queue.Clear(); await NewConversationAsync(); } else RenderHistory();
    }

    /// Moves every transcript recorded for this directory to the server's trash; the project's files are not touched.
    private async Task TrashProjectAsync(string path)
    {
        if (busy && conversation?.Directory == path) throw new IOException("请先停止此项目的任务");
        var behind = parked.Values.Where(p => p.Conversation.Directory == path).ToList();
        if (behind.Any(p => p.Active)) throw new IOException("此项目还有对话在后台回复或排队，请先打开并停止它们");
        if (behind.Any(p => p.Tasks.Any(item => Presentation.Text(item?["status"]) == "running"))) throw new IOException("此项目还有后台任务在运行，请先在状态页停止它们");
        // Closing the open conversation's worker would also end what it still runs in the background.
        if (taskId is not null && (conversation?.Directory == path || directory.Text == path) && backgroundTasks.Any(item => Presentation.Text(item?["status"]) == "running"))
            throw new IOException("此项目还有后台任务在运行，请先在状态页停止它们");
        var remote = RequireAgent();
        int count = history.Count(c => c.Directory == path);
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot, Title = "把项目历史移到废纸篓",
            Content = new TextBlock { Text = $"{path}\n\n这个目录的 {count} 条对话记录会移到服务器的废纸篓，这些对话在服务器上保留的进程会被关闭。项目里的文件不受影响。", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            PrimaryButtonText = "移到废纸篓", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        bool open = conversation?.Directory == path || (taskId is not null && directory.Text == path);
        if (open) await ConfirmLeavingQueueAsync();
        // The server refuses while a worker for this directory is alive, and a worker stays alive after its reply. Close the idle ones first.
        var prefix = LocalState.HostKey(host!) + "|";
        var workers = history.Where(c => c.Directory == path && c.SessionId is not null && local.Tasks.ContainsKey(prefix + c.SessionId)).Select(c => local.Tasks[prefix + c.SessionId!]).ToHashSet();
        if (open && taskId is not null) workers.Add(taskId);
        foreach (var p in behind) { if (!p.Done) workers.Add(p.TaskId); parked.Remove(p.TaskId); }
        foreach (var worker in workers)
        {
            try { await remote.TaskCommandAsync(worker, new { kind = "close" }); } catch (IOException) { } // Already gone.
            foreach (var key in local.Tasks.Where(pair => pair.Value == worker).Select(pair => pair.Key).ToList()) local.Tasks.Remove(key);
            if (taskId == worker) taskId = null;
        }
        if (workers.Count > 0) local.Save();
        // Conversations run as another account keep their records in that account's home, so each one is asked for separately.
        int movedCount = 0; var failed = new List<string>();
        foreach (var account in new string?[] { null }.Concat(history.Where(c => c.Directory == path && !string.IsNullOrEmpty(c.Account)).Select(c => c.Account).Distinct()))
        {
            try
            {
                JsonNode result;
                try { result = await remote.CallAsync("history", new { operation = "trashProject", directory = path, account }); }
                catch (IOException) when (workers.Count > 0)
                {
                    // A closed worker needs a moment to exit.
                    await Task.Delay(1500); result = await remote.CallAsync("history", new { operation = "trashProject", directory = path, account });
                }
                movedCount += result["count"]?.GetValue<int>() ?? 0;
            }
            catch (IOException e) when (account is not null) { failed.Add($"账号 {account}：{e.Message}"); }
        }
        if (open) { queue.Clear(); await NewConversationAsync(); }
        await RefreshHistoryAsync();
        status.Text = $"已移走 {movedCount} 条对话记录" + (failed.Count > 0 ? "；没有移走的：" + string.Join("；", failed) : "");
    }
}
