using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json.Nodes;

namespace ClaudeMirror.App;

/// The status tab: account usage, conversation usage, context, MCP servers, plugins, Agents and background tasks of the open conversation's remote task.
public sealed partial class MainWindow
{
    private JsonArray backgroundTasks = [];

    private async Task StatusAsync()
    {
        var content = new StackPanel { Spacing = 8, Margin = new Thickness(14, 4, 14, 16) };
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(6) };
        bar.Children.Add(BackToChat()); bar.Children.Add(ActionButton("刷新", "\uE72C", StatusAsync, true));
        OpenToolTab("status", "状态", ToolArea(bar, new ScrollViewer { Content = content }));
        void Title(string text) => content.Children.Add(new TextBlock { Text = text, FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ink, Margin = new Thickness(0, 12, 0, 0) });
        void Note(string text, bool problem = false) => content.Children.Add(new TextBlock { Text = text, FontSize = 12.5, Foreground = problem ? danger : muted, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        Title("服务器");
        Note(host is null ? "未连接" : $"{host.Name} · {LocalState.HostKey(host)}");
        if (agent?.Hello is { } hello) Note($"{Presentation.Text(hello["hostname"])} · {Presentation.Text(hello["platform"])}/{Presentation.Text(hello["arch"])} · Node {Presentation.Text(hello["node"])} · Claude {(Presentation.Text(hello["claude"]) ?? "未安装")}");
        foreach (var issue in health) Note(issue.Title + "：" + issue.Detail, issue.Blocking);
        void Items(List<StatusSummary.Item> items)
        {
            foreach (var item in items)
            {
                content.Children.Add(new TextBlock { Text = item.Name, FontSize = 13, Foreground = ink, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
                if (item.Detail is not null) content.Children.Add(new TextBlock { Text = item.Detail, FontSize = 12, Foreground = muted, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, -6, 0, 0) });
            }
        }
        // Agents come from the project's catalogue, so they are listed before any message is sent.
        async Task Agents()
        {
            Title("Agents");
            try
            {
                var known = StatusSummary.Agents(lastState?["capabilities"]);
                if (known.Count == 0 && agent?.Connected == true)
                    known = StatusSummary.Agents(await agent.CallAsync("task", new { operation = "inspect", digest = agent.Digest, directory = directory.Text, action = "catalogue", preferences = new { executionUser } }));
                if (known.Count == 0) Note(agent?.Connected == true ? "这个项目没有可用的 Agent。" : "连接服务器后可查看。");
                Items(known);
            }
            catch (Exception e) { Note("读取 Agent 列表失败：" + e.Message, true); }
        }
        if (taskId is null || agent?.Connected != true)
        {
            await Agents();
            Title("会话"); Note(agent?.Connected == true ? "账号用量、对话用量、MCP、插件和后台任务来自对话的远端任务。发送一条消息后再打开这里。" : "未连接服务器。连接后可查看账号用量、MCP、插件和后台任务。");
            return;
        }
        var remote = agent; var task = taskId;
        async Task<JsonNode?> Control(string action, object? value = null) =>
            (await remote.TaskCommandAsync(task, new { kind = "control", action, value }))["value"];
        async Task Section(string title, Func<Task> load)
        {
            Title(title);
            try { await load(); } catch (Exception e) { Note(e.Message, true); }
        }
        await Section("账号用量", async () =>
        {
            var quota = await Control("accountQuota");
            foreach (var window in quota?["windows"] as JsonArray ?? [])
            {
                double used = window?["used"]?.GetValue<double>() ?? 0;
                content.Children.Add(new TextBlock { Text = $"{Presentation.Text(window?["title"])}：已用 {used:0.#}%" + (Presentation.Text(window?["resetsAt"]) is { } reset ? " · 重置 " + reset : ""), FontSize = 13, Foreground = ink });
                content.Children.Add(new ProgressBar { Value = used, Maximum = 100, HorizontalAlignment = HorizontalAlignment.Stretch });
            }
            if (quota?["available"]?.GetValue<bool>() != true) Note("远端没有返回订阅额度（可能未登录订阅账号，或 Claude Code 版本较旧）。");
        });
        Title("对话用量");
        var spent = StatusSummary.Usage(lastState?["usage"]);
        if (spent.Count == 0) Note("这个对话还没有完成的回复，回复结束后这里显示 token 和费用。");
        Items(spent);
        await Section("上下文", async () =>
        {
            var usage = await Control("context");
            double total = usage?["totalTokens"]?.GetValue<double>() ?? 0, limit = usage?["maxTokens"]?.GetValue<double>() ?? 0;
            if (limit <= 0) { Note("远端没有返回上下文用量。"); return; }
            content.Children.Add(new TextBlock { Text = $"{total:N0} / {limit:N0} tokens（{total / limit:P0}）", FontSize = 13, Foreground = ink });
            content.Children.Add(new ProgressBar { Value = total, Maximum = limit, HorizontalAlignment = HorizontalAlignment.Stretch });
        });
        await Section("MCP 服务器", async () =>
        {
            var runtime = await Control("runtimeStatus");
            var actions = (runtime?["actions"] as JsonArray ?? []).Select(action => Presentation.Text(action)).ToHashSet();
            var servers = runtime?["servers"] as JsonArray ?? [];
            if (servers.Count == 0) Note("这个项目没有配置 MCP 服务器。");
            foreach (var server in servers)
            {
                if (Presentation.Text(server?["name"]) is not { } name) continue;
                var state = Presentation.Text(server!["status"]) ?? "";
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                row.Children.Add(new TextBlock { Text = $"{name} · {state}" + (server["tools"] is JsonArray tools ? $" · {tools.Count} 个工具" : ""), FontSize = 13, Foreground = state is "failed" or "needs-auth" ? danger : ink, VerticalAlignment = VerticalAlignment.Center });
                if (actions.Contains("reconnectMcp")) row.Children.Add(Button("重连", async () => { await Control("manageRuntime", new { action = "reconnectMcp", name }); await StatusAsync(); }));
                if (actions.Contains("toggleMcp")) row.Children.Add(Button(state == "disabled" ? "启用" : "停用", async () => { await Control("manageRuntime", new { action = "toggleMcp", name, enabled = state == "disabled" }); await StatusAsync(); }));
                content.Children.Add(row);
                if (Presentation.Text(server["error"]) is { Length: > 0 } error) Note(error, true);
            }
            Title("插件");
            var plugins = StatusSummary.Plugins(lastState);
            if (plugins.Count == 0) Note("这个对话没有加载插件。");
            Items(plugins);
            if (actions.Contains("reloadPlugins"))
                content.Children.Add(Button("重新加载插件", async () =>
                {
                    var result = await Control("manageRuntime", new { action = "reloadPlugins" });
                    await StatusAsync();
                    if (result?["held"]?.GetValue<bool>() == true) status.Text = "重新加载会让提示缓存失效，Claude 已推迟到下一次合适的时机";
                }));
        });
        await Agents();
        Title("后台任务");
        var running = backgroundTasks.Where(item => Presentation.Text(item?["status"]) == "running").ToList();
        if (running.Count == 0) Note("没有正在运行的后台任务。");
        foreach (var item in running)
        {
            if (Presentation.Text(item?["id"]) is not { } id) continue;
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Children.Add(new TextBlock { Text = Presentation.Text(item!["description"]) ?? Presentation.Text(item["command"]) ?? id, FontSize = 13, Foreground = ink, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 420 });
            row.Children.Add(Button("停止", async () => { await Control("stopTask", id); await StatusAsync(); }));
            content.Children.Add(row);
        }
    }

    /// The whole conversation as one block of text. Selection in the chat stops at each bubble, because every block is its own control;
    /// here it runs from any message to any other.
    private Task TranscriptAsync()
    {
        var entries = Transcript.Entries(messages.Children.OfType<FrameworkElement>().Select(element => element.Tag).OfType<MessageView>().Select(view => (view.User, view.Plain)));
        if (entries.Count == 0) throw new IOException("这个对话还没有可以选择的文字");
        var text = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 14, Foreground = ink, Margin = new Thickness(18, 6, 18, 18), LineHeight = 22 };
        foreach (var entry in entries)
        {
            var paragraph = new Microsoft.UI.Xaml.Documents.Paragraph { Margin = new Thickness(0, 0, 0, 14) };
            paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = Transcript.Speaker(entry.User) + "：", Foreground = entry.User ? sage : muted, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.LineBreak());
            paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = entry.Text });
            text.Blocks.Add(paragraph);
        }
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(6) };
        bar.Children.Add(BackToChat());
        bar.Children.Add(ActionButton("全选", "\uE8B3", () => { text.Focus(FocusState.Programmatic); text.SelectAll(); return Task.CompletedTask; }, true));
        bar.Children.Add(ActionButton("复制选中的文字", "\uE8C8", () =>
        {
            // Nothing selected copies the whole conversation.
            Copy(text.SelectedText.Length > 0 ? text.SelectedText : Transcript.Text(entries.Select(entry => (entry.User, entry.Text))));
            status.Text = "已复制"; return Task.CompletedTask;
        }, true));
        bar.Children.Add(ActionButton("刷新", "\uE72C", TranscriptAsync, true));
        OpenToolTab("transcript", "对话文本", ToolArea(bar, new ScrollViewer { Content = text }));
        return Task.CompletedTask;
    }
}
