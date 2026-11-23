using ClaudeMirror.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace ClaudeMirror.App;

/// Demo scenes: the real window on fixture data, with no SSH. Used for screenshots.
///   CLAUDE_MIRROR_DEMO      home | chat | permission | finished
///   CLAUDE_MIRROR_THEME     light | dark
///   CLAUDE_MIRROR_SIZE      for example 1280x800
///   CLAUDE_MIRROR_SCROLL    transcript offset in pixels; default is the newest message
///   CLAUDE_MIRROR_SNAPSHOT  PNG path: save the window content there and exit
public sealed partial class MainWindow
{
    private static readonly string? DemoScene = Environment.GetEnvironmentVariable("CLAUDE_MIRROR_DEMO");

    /// The demo never reads or writes the user's saved hosts.
    private static string StateFolder() => DemoScene is not null
        ? Path.Combine(Path.GetTempPath(), "claude-mirror-demo-" + Guid.NewGuid().ToString("N"))
        : Environment.GetEnvironmentVariable("CLAUDE_MIRROR_STATE_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "claude-mirror");

    private void PrepareDemo()
    {
        if (DemoScene is null) return;
        if (Environment.GetEnvironmentVariable("CLAUDE_MIRROR_THEME") is { } theme)
            root.RequestedTheme = theme == "dark" ? ElementTheme.Dark : ElementTheme.Light;
        var size = Environment.GetEnvironmentVariable("CLAUDE_MIRROR_SIZE")?.Split('x');
        if (size?.Length == 2 && int.TryParse(size[0], out var width) && int.TryParse(size[1], out var height))
            AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
        root.Loaded += async (_, _) =>
        {
            var snapshot = Environment.GetEnvironmentVariable("CLAUDE_MIRROR_SNAPSHOT");
            try
            {
                await ShowDemoAsync(DemoScene);
                if (snapshot is null) return;
                await Task.Delay(1500); // Let layout, images and the follow-to-newest scroll settle.
                if (double.TryParse(Environment.GetEnvironmentVariable("CLAUDE_MIRROR_SCROLL"), out var offset))
                {
                    scroll.ChangeView(null, offset, null, true); await Task.Delay(500);
                }
                await SaveSnapshotAsync(snapshot);
                Close();
            }
            catch (Exception e)
            {
                status.Text = e.Message;
                if (snapshot is null) return;
                File.WriteAllText(snapshot + ".error.txt", e.ToString());
                Environment.Exit(1);
            }
        };
    }

    private async Task ShowDemoAsync(string scene)
    {
        var profile = new HostProfile("演示服务器", "demo.example", 22, "dev");
        var demo = await new DemoAgent().ConnectAsync(profile);
        agent = demo; host = profile; local.Hosts.Add(profile);
        hosts.ItemsSource = local.Hosts.ToList(); hosts.SelectedItem = profile;
        await AfterAgentStartedAsync(demo);
        await RefreshHealthAsync();
        if (scene == "home") return;
        local.Tasks[LocalState.HostKey(profile) + "|s-auth"] = scene switch { "permission" => DemoAgent.PermissionTaskId, "finished" => DemoAgent.FinishedTaskId, _ => DemoAgent.TaskId };
        // One conversation left replying in the background, as the sidebar lists it.
        parked["demo-background"] = new Parked
        {
            Conversation = new Conversation("重构上传重试逻辑", history[0].Directory, null, null), TaskId = "demo-background",
            Queue = new SendQueue(), PermissionMode = "default", ExecutionUser = "", Views = [], Busy = true
        };
        await SelectAsync(history[0]);
        // A queue held back after the reply ended, with its send-now, edit and remove buttons.
        if (scene == "finished") { queue.Add("测试通过后更新 README 的接口说明"); queue.Pause(); RenderQueue(); }
        if (scene != "permission") return;
        queue.Add("推送之后顺便开一个 PR"); queue.Add("再把 CHANGELOG 更新一下"); RenderQueue();
    }

    private async Task SaveSnapshotAsync(string path)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(root);
        var pixels = (await bitmap.GetPixelsAsync()).ToArray();
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        await using var file = File.Create(path);
        await stream.AsStreamForRead().CopyToAsync(file);
    }
}
