using ClaudeMirror.Core;
using Xunit;

public sealed class RemoteSmokeFactAttribute : FactAttribute
{
    public RemoteSmokeFactAttribute()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MIRROR_SMOKE_HOST")))
            Skip = "Set MIRROR_SMOKE_HOST and pinned connection details for the integration test";
    }
}

public class RemoteSmokeTests
{
    [RemoteSmokeFact] public async Task ConnectReadHistoryAndOptionallyChat()
    {
        var host = Environment.GetEnvironmentVariable("MIRROR_SMOKE_HOST");
        if (string.IsNullOrEmpty(host)) return;
        var profile = new HostProfile("smoke", host, int.Parse(Environment.GetEnvironmentVariable("MIRROR_SMOKE_PORT") ?? "22"), Environment.GetEnvironmentVariable("MIRROR_SMOKE_USER")!, Environment.GetEnvironmentVariable("MIRROR_SMOKE_KEY"));
        using var remote = new RemoteAgent();
        var expected = Environment.GetEnvironmentVariable("MIRROR_SMOKE_FINGERPRINT");
        Assert.False(string.IsNullOrEmpty(expected));
        await remote.ConnectAsync(profile, "", "", Environment.GetEnvironmentVariable("MIRROR_SMOKE_RESOURCES")!, fingerprint => Task.FromResult(fingerprint == expected));
        Assert.StartsWith("/", remote.Home);
        var history = await remote.CallAsync("history", new { operation = "list", offset = 0 });
        Assert.NotNull(history["sessions"]);
        var files = await remote.CallAsync("file", new { operation = "list", path = remote.Home });
        Assert.NotNull(files["entries"]);
        if (Environment.GetEnvironmentVariable("MIRROR_SMOKE_CHAT") != "1") return;
        var task = Guid.NewGuid().ToString();
        var finished = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            await remote.CallAsync("task", new { operation = "start", taskId = task, digest = remote.Digest, request = new
            {
                session = new { id = Guid.NewGuid().ToString(), host = profile.Host, directory = remote.Home, name = "Windows native smoke", messages = new[] { new { id = Guid.NewGuid().ToString(), role = "assistant", blocks = Array.Empty<object>() } }, permissions = Array.Empty<object>(), preferences = new { } },
                prompt = "Reply with WINDOWS-NATIVE-OK only. Do not use tools or change files."
            }});
            await remote.WatchAsync(task, state =>
            {
                if (state["status"]?.GetValue<string>() == "error") finished.TrySetException(new IOException(state["message"]?.ToJsonString()));
                if (state["status"]?.GetValue<string>() == "idle") finished.TrySetResult(Protocol.MessageText(state["message"]));
            });
            Assert.Contains("WINDOWS-NATIVE-OK", await finished.Task.WaitAsync(TimeSpan.FromSeconds(90)));
            var catalogue = await remote.TaskCommandAsync(task, new { kind = "control", action = "catalogue" });
            Assert.NotNull(catalogue);
        }
        finally { await remote.TaskCommandAsync(task, new { kind = "close" }); }

    }
}
