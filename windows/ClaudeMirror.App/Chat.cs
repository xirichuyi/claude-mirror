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
}
