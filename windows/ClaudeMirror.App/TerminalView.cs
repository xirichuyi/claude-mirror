using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using ClaudeMirror.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using Windows.ApplicationModel.DataTransfer;

namespace ClaudeMirror.App;

/// A shell on the server in an editor tab: xterm.js in WebView2 draws it, the existing SSH connection carries it.
public sealed partial class MainWindow
{
    private const string TerminalTag = "terminal:";
    private readonly Dictionary<string, TerminalPane> terminals = [];

    private string TerminalKey() => TerminalTag + (host is { } profile ? LocalState.HostKey(profile) : "") + "\n" + directory.Text;

    /// Opens the shell for this server and folder, or goes back to the conversation when it is already in front.
    private Task ToggleTerminalAsync()
    {
        var key = TerminalKey();
        var front = editorTabs.SelectedItem is TabViewItem { Tag: string tag } && tag == key;
        if (front && showEditor) { showEditor = false; LayoutSplit(); return Task.CompletedTask; }
        if (!terminals.TryGetValue(key, out var pane))
        {
            RequireShell();
            var folder = directory.Text;
            pane = new TerminalPane(this, folder, (columns, rows) => RequireShell().OpenTerminal(folder, columns, rows));
            terminals[key] = pane;
        }
        var name = directory.Text.TrimEnd('/'); name = name.Length == 0 ? "/" : name[(name.LastIndexOf('/') + 1)..];
        var tab = OpenToolTab(key, name, pane.Area);
        ToolTipService.SetToolTip(tab, directory.Text);
        pane.Focus();
        return Task.CompletedTask;
    }

    private RemoteAgent RequireShell() => agent?.SshConnected == true ? agent : throw new IOException("请先连接服务器");

    private void CloseTerminal(object? tag)
    {
        if (tag is string key && terminals.Remove(key, out var pane)) pane.Dispose();
    }

    private void CloseTerminals() { foreach (var pane in terminals.Values) pane.Dispose(); terminals.Clear(); }

    private sealed class TerminalPane : IDisposable
    {
        private const int Kept = 256 * 1024;
        private readonly MainWindow window;
        private readonly Func<int, int, IRemoteTerminal> open;
        private readonly WebView2 view = new();
        private readonly Button reopen;
        private readonly LinkedList<byte[]> recent = new();
        private readonly List<byte> pending = [];
        private int recentSize, columns = 80, rows = 24;
        private bool ready, flushing, closed;
        private IRemoteTerminal? shell;
        private Channel<Action<IRemoteTerminal>>? outgoing;
        public Grid Area { get; }

        public TerminalPane(MainWindow window, string folder, Func<int, int, IRemoteTerminal> open)
        {
            this.window = window; this.open = open;
            reopen = window.ActionButton("重新打开", "\uE72C", () => { Start(); return Task.CompletedTask; });
            reopen.Visibility = Visibility.Collapsed;
            var title = new TextBlock { Text = folder, FontSize = 12, Foreground = window.muted, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            var bar = Row(new FontIcon { Glyph = "\uE756", FontSize = 13, Foreground = window.muted }, title, reopen);
            bar.Spacing = 6; bar.Margin = new Thickness(10, 4, 6, 4);
            Area = window.ToolArea(bar, view);
            view.Loaded += async (_, _) => await InitializeAsync();
        }

        private async Task InitializeAsync()
        {
            try
            {
                await view.EnsureCoreWebView2Async();
                var web = view.CoreWebView2;
                if (web.Source.StartsWith("https://terminal.claude-mirror/")) return;
                web.Settings.AreDevToolsEnabled = false; web.Settings.AreDefaultContextMenusEnabled = false;
                web.Settings.IsStatusBarEnabled = false; web.Settings.IsZoomControlEnabled = false;
                web.SetVirtualHostNameToFolderMapping("terminal.claude-mirror", Path.Combine(AppContext.BaseDirectory, "Assets", "terminal"), CoreWebView2HostResourceAccessKind.Deny);
                web.NewWindowRequested += (_, e) => e.Handled = true;
                web.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith("https://terminal.claude-mirror/")) e.Cancel = true; };
                web.WebMessageReceived += (_, e) => Receive(JsonNode.Parse(e.WebMessageAsJson)!.AsObject());
                view.DefaultBackgroundColor = window.canvas.Color;
                web.Navigate("https://terminal.claude-mirror/index.html");
            }
            catch (Exception e) when (e is not OutOfMemoryException) { window.status.Text = "终端需要 WebView2 运行时"; }
        }

        public void Focus() { if (ready) Post(new JsonObject { ["focus"] = true }); else view.Focus(FocusState.Programmatic); }

        private void Receive(JsonObject message)
        {
            switch (message["t"]?.GetValue<string>())
            {
                case "ready":
                    // A fresh page, also after WebView2 reloads it: theme first, then what the shell printed so far.
                    ready = true; Size(message);
                    Post(new JsonObject { ["theme"] = Theme() });
                    foreach (var chunk in recent) Post(new JsonObject { ["o"] = Convert.ToBase64String(chunk) });
                    if (shell is null && !closed) Start(); else Send(s => s.Resize(columns, rows));
                    Post(new JsonObject { ["focus"] = true });
                    break;
                case "in":
                    var text = message["d"]!.GetValue<string>();
                    var bytes = message["b"]?.GetValue<bool>() == true ? Encoding.Latin1.GetBytes(text) : Encoding.UTF8.GetBytes(text);
                    Send(s => { s.Input.Write(bytes); s.Input.Flush(); });
                    break;
                case "size": Size(message); Send(s => s.Resize(columns, rows)); break;
                case "copy":
                    var copied = new DataPackage(); copied.SetText(message["d"]!.GetValue<string>()); Clipboard.SetContent(copied);
                    break;
                case "paste": _ = PasteAsync(); break;
                case "toggle": _ = window.RunAsync(window.ToggleTerminalAsync); break;
            }
        }

        private void Size(JsonObject message)
        {
            if (message["c"]?.GetValue<int>() is int c and > 0) columns = c;
            if (message["r"]?.GetValue<int>() is int r and > 0) rows = r;
        }

        private async Task PasteAsync()
        {
            var content = Clipboard.GetContent();
            if (!content.Contains(StandardDataFormats.Text)) return;
            Post(new JsonObject { ["p"] = await content.GetTextAsync() });
        }

        private JsonObject Theme() => new()
        {
            ["background"] = Css(window.canvas), ["foreground"] = Css(window.ink), ["cursor"] = Css(window.ink),
            ["cursorAccent"] = Css(window.canvas), ["selectionBackground"] = Css(window.selected),
        };
        private static string Css(SolidColorBrush brush) => $"#{brush.Color.R:x2}{brush.Color.G:x2}{brush.Color.B:x2}";

        /// Starts a shell off the UI thread. Keys and resizes wait in order until it is up, then go out on one background reader.
        private void Start()
        {
            if (closed) return;
            reopen.Visibility = Visibility.Collapsed;
            if (ready) Post(new JsonObject { ["reset"] = true });
            recent.Clear(); recentSize = 0;
            var queue = Channel.CreateUnbounded<Action<IRemoteTerminal>>(new UnboundedChannelOptions { SingleReader = true });
            outgoing = queue;
            int width = columns, height = rows;
            var dispatcher = DispatcherQueue.GetForCurrentThread();
            _ = Task.Run(async () =>
            {
                IRemoteTerminal started;
                try { started = open(width, height); }
                catch (Exception e) when (e is IOException or InvalidOperationException or Renci.SshNet.Common.SshException or System.ComponentModel.Win32Exception or PlatformNotSupportedException)
                {
                    dispatcher.TryEnqueue(() => { window.status.Text = e.Message; Ended(queue); });
                    return;
                }
                dispatcher.TryEnqueue(() => { if (closed || outgoing != queue) started.Dispose(); else shell = started; });
                var writing = Task.Run(async () =>
                {
                    await foreach (var action in queue.Reader.ReadAllAsync())
                        try { action(started); } catch (Exception e) when (e is IOException or ObjectDisposedException or Renci.SshNet.Common.SshException) { }
                });
                var buffer = new byte[64 * 1024];
                try
                {
                    while (true)
                    {
                        int count = await started.Output.ReadAsync(buffer);
                        if (count == 0) break;
                        var chunk = buffer[..count];
                        dispatcher.TryEnqueue(() => { if (outgoing == queue) Output(chunk); });
                    }
                }
                catch (Exception e) when (e is IOException or ObjectDisposedException or Renci.SshNet.Common.SshException) { }
                queue.Writer.TryComplete(); await writing;
                dispatcher.TryEnqueue(() => { if (outgoing == queue) { started.Dispose(); Ended(queue); } });
            });
        }

        private void Ended(Channel<Action<IRemoteTerminal>> queue)
        {
            if (outgoing != queue) return;
            queue.Writer.TryComplete(); shell = null;
            if (!closed) reopen.Visibility = Visibility.Visible;
        }

        private void Send(Action<IRemoteTerminal> action) => outgoing?.Writer.TryWrite(action);

        /// Output is batched per UI turn, and the last part is kept for a page that has to be drawn again.
        private void Output(byte[] chunk)
        {
            recent.AddLast(chunk); recentSize += chunk.Length;
            while (recentSize > Kept && recent.First is { } first) { recentSize -= first.Value.Length; recent.RemoveFirst(); }
            if (!ready) return;
            pending.AddRange(chunk);
            if (flushing) return;
            flushing = true;
            DispatcherQueue.GetForCurrentThread().TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                flushing = false;
                if (pending.Count == 0) return;
                Post(new JsonObject { ["o"] = Convert.ToBase64String(pending.ToArray()) }); pending.Clear();
            });
        }

        private void Post(JsonObject message)
        {
            if (view.CoreWebView2 is { } web) web.PostWebMessageAsJson(message.ToJsonString());
        }

        public void Dispose()
        {
            if (closed) return;
            closed = true; outgoing?.Writer.TryComplete(); outgoing = null;
            shell?.Dispose(); shell = null;
            view.Close();
        }
    }
}
