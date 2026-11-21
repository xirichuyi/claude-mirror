using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Text.Json.Nodes;
using Windows.System;

namespace ClaudeMirror.App;

/// The project panel beside the conversation: git changes with side-by-side diffs, content search, quick open, worktrees and PDF preview.
public sealed partial class MainWindow
{
    private const int SplitRowLimit = 1500, PdfPageLimit = 30;

    /// A tab in the editor pane that is not a file being edited. Opening the same key again selects the existing tab and replaces its content.
    private TabViewItem OpenToolTab(string key, string header, FrameworkElement content)
    {
        var tab = editorTabs.TabItems.OfType<TabViewItem>().FirstOrDefault(item => item.Tag as string == key);
        if (tab is null) { tab = new TabViewItem { Tag = key }; editorTabs.TabItems.Add(tab); }
        tab.Header = header; tab.Content = content;
        editorTabs.SelectedItem = tab; showEditor = true; LayoutSplit();
        return tab;
    }
    private void CloseToolTabs()
    {
        foreach (var tab in editorTabs.TabItems.OfType<TabViewItem>().Where(item => item.Tag is string).ToList()) editorTabs.TabItems.Remove(tab);
        LayoutSplit();
    }

    private Grid ToolArea(FrameworkElement header, FrameworkElement body)
    {
        var area = Rows(GridLength.Auto, new GridLength(1, GridUnitType.Star)); area.Background = canvas;
        area.Children.Add(header); Grid.SetRow(body, 1); area.Children.Add(body);
        return area;
    }

    private Button BackToChat() => ActionButton("返回对话", "\uE72B", () => { showEditor = false; LayoutSplit(); return Task.CompletedTask; });

    // ---- git changes

    private async Task ChangesAsync()
    {
        var remote = RequireAgent(); var project = directory.Text;
        var state = await remote.CallAsync("file", new { operation = "gitStatus", @base = project });
        var list = new StackPanel { Spacing = 2, Margin = new Thickness(8, 0, 8, 12) };
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(6) };
        bar.Children.Add(BackToChat()); bar.Children.Add(ActionButton("刷新", "\uE72C", ChangesAsync, true));
        bool repository = state["repository"]?.GetValue<bool>() == true;
        if (repository)
        {
            var branch = new TextBox { PlaceholderText = "新分支名，例如 feature/login", Width = 240 };
            var create = Button("创建并在其中新建对话", async () =>
            {
                // Everything that can refuse the new conversation is settled before the branch and directory exist.
                if (busy) throw new IOException("请先停止当前回复");
                await ConfirmLeavingQueueAsync();
                var made = await remote.CallAsync("file", new { operation = "createWorktree", @base = project, branch = branch.Text.Trim() });
                queue.Clear(); await NewConversationAsync(); directory.Text = made["path"]!.GetValue<string>(); await RefreshCapabilitiesAsync();
                status.Text = "已创建工作区 " + directory.Text;
            });
            var worktree = ActionButton("新建 worktree", "\uE8F4", () => Task.CompletedTask, true);
            worktree.Flyout = new Flyout { Content = new StackPanel { Spacing = 10, Children = { new TextBlock { Text = "从当前 HEAD 新建分支和独立的工作目录", FontSize = 12, Foreground = muted }, branch, create } } };
            bar.Children.Add(worktree);
        }
        var files = state["files"] as JsonArray ?? [];
        list.Children.Add(new TextBlock
        {
            Text = !repository ? ShortDirectory(project) + " 不是 Git 仓库" : (Presentation.Text(state["branch"]) ?? "") + (files.Count == 0 ? " · 工作区是干净的" : $" · {files.Count} 个文件有改动"),
            FontSize = 12, Foreground = muted, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 0, 0, 6)
        });
        foreach (var file in files)
        {
            if (Presentation.Text(file?["path"]) is not { } path) continue;
            var (letter, label) = Workspace.Status(Presentation.Text(file!["status"]) ?? "");
            var relative = Presentation.Text(file["relative"]) ?? path;
            var row = Button(relative, () => DiffAsync(path, relative));
            row.Content = Row(new TextBlock { Text = letter, Width = 14, FontFamily = Mono, Foreground = letter is "D" or "!" ? danger : letter is "U" or "A" ? sage : amber }, new TextBlock { Text = relative, TextTrimming = TextTrimming.CharacterEllipsis });
            row.HorizontalAlignment = HorizontalAlignment.Stretch; row.HorizontalContentAlignment = HorizontalAlignment.Left;
            row.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); row.BorderThickness = new Thickness(0);
            ToolTipService.SetToolTip(row, label + " · " + path); list.Children.Add(row);
        }
        if (state["truncated"]?.GetValue<bool>() == true) list.Children.Add(new TextBlock { Text = "改动的文件太多，只显示前 2000 个", FontSize = 12, Foreground = muted });
        OpenToolTab("changes", "变更", ToolArea(bar, new ScrollViewer { Content = list }));
    }

    private async Task DiffAsync(string path, string relative)
    {
        var remote = RequireAgent();
        var result = await remote.CallAsync("file", new { operation = "gitFileDiff", path, @base = directory.Text });
        var rows = Workspace.Split(Presentation.Text(result["text"]) ?? "");
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(6) };
        bar.Children.Add(BackToChat()); bar.Children.Add(ActionButton("打开文件", "\uE8E5", () => PreviewAsync(path), true));
        bar.Children.Add(new TextBlock { Text = relative, FontSize = 12, Foreground = muted, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        OpenToolTab("diff:" + path, "± " + Path.GetFileName(path), ToolArea(bar, SplitDiff(rows)));
    }

    /// Old text on the left, new text on the right. Both sides share one vertical scroll; each scrolls sideways on its own.
    private FrameworkElement SplitDiff(IReadOnlyList<SplitRow> rows)
    {
        if (rows.Count == 0) return new TextBlock { Text = "没有可显示的差异", Foreground = muted, FontSize = 13, Margin = new Thickness(14) };
        var left = new StackPanel(); var right = new StackPanel();
        Border Line(int? number, string? text, Brush? tint) => new()
        {
            Height = 20, Background = tint, Padding = new Thickness(6, 0, 12, 0),
            Child = text is null ? null : new TextBlock { Text = (number?.ToString() ?? "").PadLeft(5) + "  " + text, FontFamily = Mono, FontSize = 12.5, Foreground = ink, TextWrapping = TextWrapping.NoWrap, IsTextSelectionEnabled = true }
        };
        foreach (var row in rows.Take(SplitRowLimit))
        {
            if (row.Kind == DiffKind.Hunk)
            {
                left.Children.Add(new Border { Height = 20, Padding = new Thickness(6, 0, 12, 0), Child = new TextBlock { Text = row.Left, FontFamily = Mono, FontSize = 12, Foreground = muted, TextWrapping = TextWrapping.NoWrap } });
                right.Children.Add(new Border { Height = 20 });
                continue;
            }
            bool changed = row.Kind != DiffKind.Context;
            left.Children.Add(Line(row.LeftLine, row.Left, changed && row.Left is not null ? removed : null));
            right.Children.Add(Line(row.RightLine, row.Right, changed && row.Right is not null ? added : null));
        }
        ScrollViewer Side(StackPanel lines) => new() { Content = lines, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollMode = ScrollMode.Disabled };
        var sides = new Grid(); sides.ColumnDefinitions.Add(new ColumnDefinition()); sides.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) }); sides.ColumnDefinitions.Add(new ColumnDefinition());
        var rightSide = Side(right); var divider = new Border { Background = edge };
        sides.Children.Add(Side(left)); Grid.SetColumn(divider, 1); sides.Children.Add(divider); Grid.SetColumn(rightSide, 2); sides.Children.Add(rightSide);
        var content = new StackPanel(); content.Children.Add(sides);
        if (rows.Count > SplitRowLimit) content.Children.Add(new TextBlock { Text = $"还有 {rows.Count - SplitRowLimit} 行未显示", FontSize = 12, Foreground = muted, Margin = new Thickness(10, 8, 0, 8) });
        return new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    // ---- search in files

    private Task SearchFilesAsync()
    {
        var query = new TextBox { PlaceholderText = "在项目文件里搜索文字，按 Enter 开始", MinWidth = 260 };
        var results = new StackPanel { Spacing = 2, Margin = new Thickness(8, 0, 8, 12) };
        async Task Run()
        {
            var remote = RequireAgent(); var text = query.Text;
            if (text.Length == 0) { results.Children.Clear(); return; }
            results.Children.Clear(); results.Children.Add(new TextBlock { Text = "正在搜索…", FontSize = 12, Foreground = muted });
            var found = await remote.CallAsync("file", new { operation = "search", @base = directory.Text, query = text });
            if (query.Text != text) return; // A newer search replaced this one.
            results.Children.Clear();
            var matches = found["matches"] as JsonArray ?? [];
            results.Children.Add(new TextBlock { Text = matches.Count == 0 ? "没有找到匹配的内容" : $"{matches.Count} 处匹配" + (found["truncated"]?.GetValue<bool>() == true ? "（结果太多，只显示前 500 处）" : ""), FontSize = 12, Foreground = muted, Margin = new Thickness(4, 0, 0, 6) });
            foreach (var group in matches.Where(match => match is not null).GroupBy(match => Presentation.Text(match!["path"]) ?? ""))
            {
                var path = group.Key;
                results.Children.Add(new TextBlock { Text = Presentation.Text(group.First()!["relative"]) ?? path, FontSize = 12.5, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ink, Margin = new Thickness(4, 8, 0, 2), TextTrimming = TextTrimming.CharacterEllipsis });
                foreach (var match in group)
                {
                    var line = (match!["line"]?.GetValue<int>() ?? 0).ToString().PadLeft(5) + "  " + (Presentation.Text(match["text"]) ?? "").Trim();
                    var row = Button(line, () => PreviewAsync(path));
                    row.Content = new TextBlock { Text = line, FontFamily = Mono, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
                    row.HorizontalAlignment = HorizontalAlignment.Stretch; row.HorizontalContentAlignment = HorizontalAlignment.Left; row.Padding = new Thickness(6, 2, 6, 2);
                    row.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); row.BorderThickness = new Thickness(0);
                    results.Children.Add(row);
                }
            }
        }
        query.KeyDown += async (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; await RunAsync(Run); } };
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(6) };
        bar.Children.Add(BackToChat()); bar.Children.Add(query); bar.Children.Add(Button("搜索", Run));
        OpenToolTab("search", "搜索", ToolArea(bar, new ScrollViewer { Content = results }));
        query.Focus(FocusState.Programmatic);
        return Task.CompletedTask;
    }

    // ---- quick open (Ctrl+P)

    private async Task QuickOpenAsync()
    {
        var remote = RequireAgent();
        var query = new TextBox { PlaceholderText = "输入文件名的一部分" };
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true, Height = 320 };
        var paths = new List<string>(); string? chosen = null; int request = 0;
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "快速打开", Content = new StackPanel { Spacing = 10, Width = 460, Children = { query, list } }, CloseButtonText = "取消", Background = canvas };
        async Task Load()
        {
            int mine = ++request;
            try
            {
                var found = await remote.CallAsync("file", new { operation = "suggest", @base = directory.Text, query = query.Text });
                if (mine != request) return;
                paths = (found["files"] as JsonArray ?? []).Select(file => Presentation.Text(file?["path"])).Where(path => path is not null).Select(path => path!).ToList();
                list.ItemsSource = (found["files"] as JsonArray ?? []).Where(file => Presentation.Text(file?["path"]) is not null).Select(file => Presentation.Text(file!["relative"]) ?? Presentation.Text(file["path"])!).ToList();
                if (paths.Count > 0) list.SelectedIndex = 0;
            }
            catch (Exception e) { if (mine == request) list.ItemsSource = new[] { e.Message }; paths = []; }
        }
        void Choose(int index) { if (index >= 0 && index < paths.Count) { chosen = paths[index]; dialog.Hide(); } }
        query.TextChanged += async (_, _) => await Load();
        query.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter) { e.Handled = true; Choose(Math.Max(0, list.SelectedIndex)); }
            else if (e.Key == VirtualKey.Down && list.SelectedIndex < paths.Count - 1) { e.Handled = true; list.SelectedIndex++; }
            else if (e.Key == VirtualKey.Up && list.SelectedIndex > 0) { e.Handled = true; list.SelectedIndex--; }
        };
        list.ItemClick += (_, e) => Choose(list.Items.IndexOf(e.ClickedItem));
        await Load(); await dialog.ShowAsync();
        if (chosen is not null) await PreviewAsync(chosen);
    }

    // ---- PDF

    /// Renders a remote PDF's pages as images in a tab. The file is downloaded to a temporary file that is deleted afterwards.
    private async Task OpenPdfAsync(string path)
    {
        var remote = RequireAgent(); var pages = new StackPanel { Spacing = 12, Margin = new Thickness(12) };
        var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".pdf");
        try
        {
            await remote.DownloadAsync(path, file);
            var document = await Windows.Data.Pdf.PdfDocument.LoadFromFileAsync(await Windows.Storage.StorageFile.GetFileFromPathAsync(file));
            for (uint i = 0; i < Math.Min(document.PageCount, PdfPageLimit); i++)
            {
                using var page = document.GetPage(i); using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
                await page.RenderToStreamAsync(stream); stream.Seek(0);
                var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream);
                pages.Children.Add(new Border { BorderBrush = edge, BorderThickness = new Thickness(1), Child = new Image { Source = bitmap, Stretch = Stretch.Uniform, MaxWidth = 900 } });
            }
            if (document.PageCount > PdfPageLimit) pages.Children.Add(new TextBlock { Text = $"共 {document.PageCount} 页，只显示前 {PdfPageLimit} 页。下载后可查看全部。", FontSize = 12, Foreground = muted });
        }
        finally { try { File.Delete(file); } catch (IOException) { } }
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(6) };
        bar.Children.Add(BackToChat()); bar.Children.Add(ActionButton("下载", "\uE896", () => SaveCopyAsync(path), true));
        bar.Children.Add(new TextBlock { Text = path, FontSize = 12, Foreground = muted, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        OpenToolTab("pdf:" + path, Path.GetFileName(path), ToolArea(bar, new ScrollViewer { Content = pages, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto }));
    }
}
