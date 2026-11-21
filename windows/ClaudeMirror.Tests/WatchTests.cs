using System.Collections.Concurrent;
using System.IO.Pipelines;
using System.Text.Json;
using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Xunit;

public class WatchTests
{
    /// A server end that accepts every watch and lets the test publish to any subscription.
    private sealed class Server
    {
        private readonly Pipe requests = new(), replies = new();
        private readonly StreamWriter writer;
        public readonly ConcurrentDictionary<string, string> Subscriptions = new(); // subscription -> task
        public readonly ConcurrentQueue<string> Cancelled = new();
        public Server() { writer = new StreamWriter(replies.Writer.AsStream()) { AutoFlush = true }; }
        public async Task<RemoteAgent> ConnectAsync()
        {
            _ = Task.Run(ServeAsync);
            return await RemoteAgent.AttachAsync(requests.Writer.AsStream(), replies.Reader.AsStream(), new HostProfile("t", "t", 22, "t"));
        }
        private readonly SemaphoreSlim gate = new(1, 1);
        public async Task Send(object value) { await gate.WaitAsync(); try { await writer.WriteLineAsync(JsonSerializer.Serialize(value)); } finally { gate.Release(); } }
        public Task Publish(string task, string status) =>
            Send(new { sub = Subscriptions.Single(pair => pair.Value == task).Key, packet = new { status, taskId = task } });
        private async Task ServeAsync()
        {
            using var reader = new StreamReader(requests.Reader.AsStream());
            await Send(new { rcc = "ready" });
            while (await reader.ReadLineAsync() is { } line)
            {
                var message = JsonNode.Parse(line)!;
                if (message["cancel"] is JsonValue cancel)
                {
                    var subscription = cancel.GetValue<string>()["sub:".Length..];
                    Subscriptions.TryRemove(subscription, out _); Cancelled.Enqueue(subscription); continue;
                }
                var id = message["id"]!.GetValue<int>();
                if (message["op"]!.GetValue<string>() == "taskWatch")
                    Subscriptions[message["params"]!["subscription"]!.GetValue<string>()] = message["params"]!["taskId"]!.GetValue<string>();
                await Send(new { id, result = new { ok = true, home = "/home/t" } });
            }
        }
    }

    private static async Task Until(Func<bool> condition)
    {
        for (int i = 0; i < 200 && !condition(); i++) await Task.Delay(10);
        Assert.True(condition());
    }

    [Fact]
    public async Task SeveralTasksAreWatchedAtOnceAndEachReceivesItsOwnState()
    {
        var server = new Server(); using var agent = await server.ConnectAsync();
        var first = new ConcurrentQueue<string>(); var second = new ConcurrentQueue<string>();
        await agent.WatchAsync("a", state => first.Enqueue(state["status"]!.GetValue<string>()));
        await agent.WatchAsync("b", state => second.Enqueue(state["status"]!.GetValue<string>()));
        Assert.Empty(server.Cancelled); // Watching b did not end the watch on a.
        await server.Publish("a", "working"); await server.Publish("b", "permission"); await server.Publish("a", "idle");
        await Until(() => first.Count == 2 && second.Count == 1);
        Assert.Equal(["working", "idle"], first); Assert.Equal(["permission"], second);
        Assert.Equal(["a", "b"], agent.Watched.Order());
    }

    [Fact]
    public async Task WatchingATaskAgainReplacesItsWatchAndUnwatchingLeavesTheOthers()
    {
        var server = new Server(); using var agent = await server.ConnectAsync();
        int stale = 0, fresh = 0, other = 0;
        await agent.WatchAsync("a", _ => Interlocked.Increment(ref stale));
        var replaced = server.Subscriptions.Single().Key;
        await agent.WatchAsync("b", _ => Interlocked.Increment(ref other));
        await agent.WatchAsync("a", _ => Interlocked.Increment(ref fresh));
        await Until(() => server.Cancelled.Contains(replaced));
        await server.Publish("a", "working"); await server.Publish("b", "working");
        await Until(() => fresh == 1 && other == 1);
        Assert.Equal(0, stale);

        await agent.UnwatchAsync("b");
        await Until(() => server.Cancelled.Count == 2);
        Assert.Equal(["a"], agent.Watched);
        await agent.UnwatchAsync("b"); // Not watched: nothing to cancel.
        await server.Publish("a", "idle");
        await Until(() => fresh == 2);
        Assert.Equal(2, server.Cancelled.Count);
    }

    [Fact]
    public void ABackgroundConversationIsLabelledByWhatItNeeds()
    {
        var working = JsonNode.Parse("""{"status":"working"}""");
        var asking = JsonNode.Parse("""{"status":"permission","permissions":[{}]}""");
        var stopped = JsonNode.Parse("""{"status":"idle","message":{"interrupted":true}}""");
        var idle = JsonNode.Parse("""{"status":"idle","message":{"blocks":[]}}""");
        Assert.True(Turn.Busy(working, false)); Assert.True(Turn.Busy(asking, false)); Assert.False(Turn.Busy(idle, false));
        Assert.True(Turn.Busy(idle, true)); // The idle snapshot of a control command sent before a prompt.
        Assert.True(Turn.NeedsAnswer(asking)); Assert.False(Turn.NeedsAnswer(working));
        Assert.True(Turn.Failed(stopped)); Assert.False(Turn.Failed(idle));
        Assert.Equal("等你确认", Turn.Label(true, true, false, 0, false));
        Assert.Equal("回复中", Turn.Label(true, false, false, 0, false));
        Assert.Equal("回复中 · 排队 2", Turn.Label(true, false, false, 2, false));
        Assert.Equal("已暂停 · 排队 1", Turn.Label(false, false, true, 1, false));
        Assert.Equal("有新回复", Turn.Label(false, false, false, 0, true));
        Assert.Null(Turn.Label(false, false, false, 0, false));
    }
}
