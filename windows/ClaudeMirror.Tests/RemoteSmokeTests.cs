using ClaudeMirror.Core;
using Xunit;

public class RemoteSmokeTests
{
    [Fact] public async Task ConnectReadHistoryAndBrowseWithoutCallingClaude()
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
    }
}
