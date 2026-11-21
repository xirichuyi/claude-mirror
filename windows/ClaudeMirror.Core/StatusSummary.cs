using System.Text.Json.Nodes;

namespace ClaudeMirror.Core;

/// <summary>Reads the plugin list, Agent list and usage figures a remote task publishes with its state.</summary>
public static class StatusSummary
{
    public sealed record Item(string Name, string? Detail);

    private static double? Number(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<double>(out var number) ? number : null;

    /// <summary>Plugins loaded for the conversation: name, then version, source and path where the server reports them.</summary>
    public static List<Item> Plugins(JsonNode? state) =>
        (state?["plugins"] as JsonArray ?? []).Select(plugin => plugin is JsonValue
            ? new Item(Presentation.Text(plugin) ?? "", null)
            : new Item(Presentation.Text(plugin?["name"]) ?? "",
                Join(Presentation.Text(plugin?["version"]) is { } version ? "v" + version : null, Presentation.Text(plugin?["source"]), Presentation.Text(plugin?["path"]))))
        .Where(item => item.Name.Length > 0).ToList();

    /// <summary>Agents Claude can hand work to, from the task's capabilities or a catalogue query.</summary>
    public static List<Item> Agents(JsonNode? capabilities) =>
        (capabilities?["agents"] as JsonArray ?? []).Select(agent =>
            new Item(Presentation.Text(agent?["name"]) ?? "", Join(Presentation.Text(agent?["description"]), Presentation.Text(agent?["model"]) is { } model ? "模型 " + model : null)))
        .Where(item => item.Name.Length > 0).ToList();

    /// <summary>What the conversation has used so far: the last turn, the reported cost, then one line per model.</summary>
    public static List<Item> Usage(JsonNode? usage)
    {
        var lines = new List<Item>();
        if (usage is not JsonObject) return lines;
        var turn = usage["lastTurn"];
        if (Number(turn?["input_tokens"]) is { } input)
        {
            double cached = (Number(turn?["cache_read_input_tokens"]) ?? 0) + (Number(turn?["cache_creation_input_tokens"]) ?? 0);
            lines.Add(new("最近一轮", $"输入 {input:N0}" + (cached > 0 ? $"（另有缓存 {cached:N0}）" : "") + $" · 输出 {Number(turn?["output_tokens"]) ?? 0:N0} tokens"
                + (Number(usage["durationMs"]) is { } duration ? $" · 用时 {Duration(duration)}" : "")));
        }
        if (Number(usage["totalCostUSD"]) is { } cost) lines.Add(new("远端报告费用", $"${cost:0.0000}（SDK 报告值，不等同于订阅账单）"));
        foreach (var (model, figures) in usage["models"] as JsonObject ?? [])
            lines.Add(new(model, Join(
                $"输入 {Number(figures?["inputTokens"]) ?? 0:N0} · 输出 {Number(figures?["outputTokens"]) ?? 0:N0} tokens",
                Number(figures?["cacheReadInputTokens"]) is > 0 and var read ? $"读缓存 {read:N0}" : null,
                Number(figures?["costUSD"]) is { } spent ? $"${spent:0.0000}" : null)));
        return lines;
    }

    private static string Duration(double milliseconds) =>
        milliseconds < 60_000 ? $"{milliseconds / 1000:0.#} 秒" : $"{(int)(milliseconds / 60_000)} 分 {(int)(milliseconds % 60_000 / 1000)} 秒";
    private static string? Join(params string?[] parts)
    {
        var text = string.Join(" · ", parts.Where(part => !string.IsNullOrWhiteSpace(part)));
        return text.Length > 0 ? text : null;
    }
}
