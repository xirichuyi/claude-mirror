using System.Text.Json.Nodes;

namespace ClaudeMirror.Core;

/// <summary>Reads the plugin list, Agent list and usage figures a remote task publishes with its state.</summary>
public static class StatusSummary
{
    public sealed record Item(string Name, string? Detail);

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

    private static string? Join(params string?[] parts)
    {
        var text = string.Join(" · ", parts.Where(part => !string.IsNullOrWhiteSpace(part)));
        return text.Length > 0 ? text : null;
    }
}
