using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeMirror.Core;

public sealed record HostProfile(string Name, string Host, int Port, string User, string? KeyFile = null);
public sealed record Conversation(string Name, string Directory, string? SessionId, string? Reference)
{
    public override string ToString() => Name;
}
public static class Protocol
{
    public static string Quote(string value) => "'" + value.Replace("'", "'\\''") + "'";
    public static JsonObject Object(object value) => JsonSerializer.SerializeToNode(value)!.AsObject();
    public static JsonObject Apply(JsonObject? previous, JsonObject packet)
    {
        if (packet["delta"]?.GetValue<bool>() != true) return (JsonObject)packet.DeepClone();
        if (previous is null || previous["version"]!.ToJsonString() != packet["base"]!.ToJsonString())
            throw new InvalidDataException("状态不连续，请重新连接");
        var state = (JsonObject)previous.DeepClone();
        foreach (var patch in packet["patches"]!.AsArray())
        {
            var path = patch!["path"]!.AsArray();
            if (path.Count == 0) throw new InvalidDataException("空状态路径");
            JsonNode parent = state;
            foreach (var key in path.Take(path.Count - 1))
                parent = parent is JsonArray a ? a[key!.GetValue<int>()]! : parent[key!.GetValue<string>()]!;
            var last = path.Last()!;
            JsonNode? old = parent is JsonArray array ? (last.GetValue<int>() < array.Count ? array[last.GetValue<int>()] : null) : parent[last.GetValue<string>()];
            JsonNode? value = patch["append"] is not null
                ? JsonValue.Create((old?.GetValue<string>() ?? "") + patch["append"]!.GetValue<string>())
                : patch["value"]?.DeepClone();
            if (parent is JsonArray items)
            {
                var i = last.GetValue<int>();
                if (patch["remove"]?.GetValue<bool>() == true) items.RemoveAt(i);
                else if (i == items.Count) items.Add(value); else items[i] = value;
            }
            else if (patch["remove"]?.GetValue<bool>() == true) parent.AsObject().Remove(last.GetValue<string>());
            else parent[last.GetValue<string>()] = value;
        }
        if (state["version"]!.ToJsonString() != packet["version"]!.ToJsonString()) throw new InvalidDataException("状态版本错误");
        return state;
    }
    public static string MessageText(JsonNode? message)
    {
        if (message is null) return "";
        if (message["text"] is JsonValue text) return text.GetValue<string>();
        var blocks = message["blocks"] as JsonArray ?? message["content"] as JsonArray;
        return string.Join("\n\n", blocks?.Select(b => b?["type"]?.GetValue<string>() switch
        {
            "text" => b?["text"]?.GetValue<string>(),
            "thinking" => "思考：" + (b?["text"]?.GetValue<string>() ?? b?["thinking"]?.GetValue<string>()),
            "tool" or "tool_use" => "▸ " + b?["name"]?.GetValue<string>() + "\n" + b?["input"]?.ToJsonString(),
            _ => null
        }).Where(t => !string.IsNullOrWhiteSpace(t)) ?? []);
    }
}

/// Only host metadata, pinned fingerprints and task IDs are stored. Never credentials.
public sealed class LocalState
{
    private readonly string file;
    public List<HostProfile> Hosts { get; set; } = [];
    public Dictionary<string, string> Fingerprints { get; set; } = [];
    public Dictionary<string, string> Tasks { get; set; } = [];
    /// <summary>Hosts whose user chose "不再询问" for password-free login.</summary>
    public HashSet<string> DeclinedKeyLogin { get; set; } = [];
    public LocalState(string folder)
    {
        Directory.CreateDirectory(folder); file = Path.Combine(folder, "state.json");
        if (!File.Exists(file)) return;
        var saved = JsonNode.Parse(File.ReadAllText(file));
        Hosts = saved?["hosts"]?.Deserialize<List<HostProfile>>() ?? [];
        Fingerprints = saved?["fingerprints"]?.Deserialize<Dictionary<string, string>>() ?? [];
        Tasks = saved?["tasks"]?.Deserialize<Dictionary<string, string>>() ?? [];
        DeclinedKeyLogin = saved?["declinedKeyLogin"]?.Deserialize<HashSet<string>>() ?? [];
    }
    public void Save()
    {
        File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(new { hosts = Hosts, fingerprints = Fingerprints, tasks = Tasks, declinedKeyLogin = DeclinedKeyLogin }));
        File.Move(file + ".tmp", file, true);
    }
    public static string HostKey(HostProfile h) => $"{h.User}@{h.Host}:{h.Port}";
}
