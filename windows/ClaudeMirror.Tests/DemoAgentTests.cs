using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Xunit;

public class DemoAgentTests
{
    private static readonly HostProfile Host = new("演示服务器", "demo.example", 22, "dev");

    [Fact]
    public async Task AnswersHistoryAndStreamsTheLiveTaskOverTheAgentProtocol()
    {
        var demo = new DemoAgent();
        using var agent = await demo.ConnectAsync(Host);
        Assert.True(agent.Connected);
        Assert.Equal("/home/dev", agent.Home);

        var page = await agent.CallAsync("history", new { operation = "list", offset = 0 });
        Assert.Equal("刷新令牌改成一次性", page["sessions"]![0]!["name"]!.GetValue<string>());
        var messages = await agent.CallAsync("history", new { operation = "messages", reference = "ref-auth" });
        Assert.Equal(3, messages["records"]!.AsArray().Count);

        var received = new TaskCompletionSource<JsonObject>();
        await agent.WatchAsync(DemoAgent.TaskId, state => received.TrySetResult(state));
        var state = await received.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("working", state["status"]!.GetValue<string>());
        Assert.Equal("Edit", state["message"]!["blocks"]![3]!["name"]!.GetValue<string>());
        Assert.Contains("history.messages", demo.Requests);
    }

    [Fact]
    public async Task ReportsOperationsTheFixturesDoNotCover()
    {
        using var agent = await new DemoAgent(new JsonObject { ["file.hello"] = new JsonObject { ["home"] = "/" } }).ConnectAsync(Host);
        var error = await Assert.ThrowsAsync<IOException>(() => agent.CallAsync("file", new { operation = "remove", path = "/x" }));
        Assert.Contains("演示模式", error.Message);
    }
}
