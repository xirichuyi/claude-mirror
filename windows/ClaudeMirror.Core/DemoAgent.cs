using System.IO.Pipelines;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeMirror.Core;

/// <summary>An in-process stand-in for the remote agent: answers the same JSON lines from fixtures, with no SSH and no server.
/// Used by the demo scenes (screenshots) and by tests.</summary>
public sealed class DemoAgent
{
    public const string TaskId = "00000000-0000-4000-8000-000000000001";
    private readonly JsonObject fixtures;
    /// <summary>Every request received, as "op.operation", for tests.</summary>
    public List<string> Requests { get; } = [];

    public DemoAgent(JsonObject? fixtures = null) => this.fixtures = fixtures ?? DemoFixtures.Load();

    /// <summary>Connects a <see cref="RemoteAgent"/> to this stand-in.</summary>
    public async Task<RemoteAgent> ConnectAsync(HostProfile profile)
    {
        var requests = new Pipe(); var replies = new Pipe();
        _ = Task.Run(() => ServeAsync(requests.Reader.AsStream(), replies.Writer.AsStream()));
        return await RemoteAgent.AttachAsync(requests.Writer.AsStream(), replies.Reader.AsStream(), profile);
    }

    private async Task ServeAsync(Stream input, Stream output)
    {
        using var reader = new StreamReader(input);
        var writer = new StreamWriter(output, new UTF8Encoding(false)) { AutoFlush = true };
        var gate = new SemaphoreSlim(1);
        async Task Send(object value)
        {
            await gate.WaitAsync();
            try { await writer.WriteLineAsync(JsonSerializer.Serialize(value)); } finally { gate.Release(); }
        }
        await Send(new { rcc = "ready" });
        while (await reader.ReadLineAsync() is { } line)
        {
            var message = JsonNode.Parse(line)!;
            if (message["id"] is null) continue; // A cancel.
            var id = message["id"]!.GetValue<int>(); var op = message["op"]!.GetValue<string>(); var parameters = message["params"] ?? new JsonObject();
            try
            {
                if (op == "taskWatch")
                {
                    await Send(new { id, result = new { subscribed = true } });
                    if (Find("taskWatch", parameters) is { } state) await Send(new { sub = parameters["subscription"]!.GetValue<string>(), packet = state });
                    continue;
                }
                await Send(new { id, result = Find(op, parameters) ?? throw new IOException("演示模式不支持这个操作") });
            }
            catch (Exception e) { await Send(new { id, error = e.Message }); }
        }
    }

    /// <summary>Looks up "op.operation:key" (key = the request's reference, path, task or action), then "op.operation".</summary>
    private JsonNode? Find(string op, JsonNode parameters)
    {
        var name = parameters["operation"] is JsonValue operation ? op + "." + operation.GetValue<string>() : op;
        lock (Requests) Requests.Add(name);
        foreach (var field in new[] { "reference", "path", "taskId", "action" })
            if (parameters[field] is JsonValue key && key.TryGetValue<string>(out var text) && fixtures[name + ":" + text] is { } exact) return exact.DeepClone();
        if (op == "task" && parameters["command"]?["action"] is JsonValue action && fixtures["task.command:" + action.GetValue<string>()] is { } control) return control.DeepClone();
        return fixtures[name]?.DeepClone();
    }
}
