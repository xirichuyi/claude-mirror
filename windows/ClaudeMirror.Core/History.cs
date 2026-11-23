using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ClaudeMirror.Core;

/// <summary>Turns the agent's history records into the same message shape a live task streams:
/// { id, role, text? , blocks: [{type:"text"|"thinking"|"tool", ...}], error? }.</summary>
public static partial class History
{
    [GeneratedRegex("<command-name>([^<]*)</command-name>", RegexOptions.Singleline)] private static partial Regex CommandName();
    [GeneratedRegex("<command-args>(.*?)</command-args>", RegexOptions.Singleline)] private static partial Regex CommandArgs();
    [GeneratedRegex("<local-command-stdout>(.*?)</local-command-stdout>", RegexOptions.Singleline)] private static partial Regex CommandOutput();
    [GeneratedRegex(@"<system-reminder>[\s\S]*?</system-reminder>\s*")] private static partial Regex Reminder();

    /// <summary>The CLI stores slash commands and their output inside XML-like tags.</summary>
    public static string UserText(string text)
    {
        if (CommandName().Match(text) is { Success: true } command)
        {
            var arguments = CommandArgs().Match(text) is { Success: true } match ? match.Groups[1].Value.Trim() : "";
            return arguments.Length == 0 ? command.Groups[1].Value.Trim() : command.Groups[1].Value.Trim() + " " + arguments;
        }
        if (CommandOutput().Match(text) is { Success: true } output) return output.Groups[1].Value.Trim();
        return Reminder().Replace(text, "").Trim();
    }

    public static List<JsonObject> Messages(JsonArray? records)
    {
        var messages = new List<JsonObject>();
        foreach (var record in records ?? [])
        {
            var id = Presentation.Text(record?["uuid"]) ?? Guid.NewGuid().ToString();
            var content = record?["message"]?["content"] as JsonArray ?? [];
            if (Presentation.Text(record?["type"]) == "user")
            {
                foreach (var result in content.Where(block => Presentation.Text(block?["type"]) == "tool_result"))
                {
                    var target = Presentation.Text(result!["tool_use_id"]);
                    var tool = messages.AsEnumerable().Reverse().SelectMany(message => message["blocks"] as JsonArray ?? [])
                        .FirstOrDefault(block => target is not null && Presentation.Text(block?["id"]) == target);
                    if (tool is null) continue;
                    tool["output"] = Presentation.Output(result["content"]);
                    if (result["is_error"] is JsonValue failed && failed.TryGetValue<bool>(out var error) && error) tool["status"] = "error";
                }
                var raw = string.Join("\n", content.Where(block => Presentation.Text(block?["type"]) == "text").Select(block => Presentation.Text(block?["text"])).Where(text => text is not null));
                var text = UserText(raw);
                if (text.Length == 0) continue;
                if (raw.Contains("<local-command-stdout>") && !raw.Contains("<command-name>"))
                    messages.Add(new JsonObject { ["id"] = id, ["role"] = "assistant", ["blocks"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text, ["format"] = "command" }) });
                else messages.Add(new JsonObject { ["id"] = id, ["role"] = "user", ["text"] = text });
            }
            else
            {
                var blocks = new JsonArray();
                foreach (var block in content)
                    switch (Presentation.Text(block?["type"]))
                    {
                        case "text": blocks.Add(new JsonObject { ["type"] = "text", ["text"] = Presentation.Text(block!["text"]) ?? "" }); break;
                        case "thinking": blocks.Add(new JsonObject { ["type"] = "thinking", ["text"] = Presentation.Text(block!["thinking"]) ?? "" }); break;
                        case "tool_use": blocks.Add(new JsonObject { ["type"] = "tool", ["id"] = Presentation.Text(block!["id"]), ["name"] = Presentation.Text(block["name"]), ["input"] = block["input"]?.DeepClone(), ["status"] = "history" }); break;
                    }
                var message = new JsonObject { ["id"] = id, ["role"] = "assistant", ["blocks"] = blocks };
                if (record?["isApiErrorMessage"] is JsonValue api && api.TryGetValue<bool>(out var apiError) && apiError || Presentation.Text(record?["error"]) is not null)
                {
                    var detail = string.Join("\n", blocks.Where(block => Presentation.Text(block?["type"]) == "text").Select(block => Presentation.Text(block?["text"])));
                    message["error"] = detail.Length > 0 ? detail : Presentation.Text(record?["error"]) ?? "远端请求失败";
                }
                // Consecutive assistant records are one reply.
                if (messages.LastOrDefault() is { } previous && Presentation.Text(previous["role"]) == "assistant" && previous["error"] is null && message["error"] is null
                    && previous["blocks"] is JsonArray earlier && Presentation.Text(earlier.FirstOrDefault()?["format"]) != "command")
                    foreach (var block in blocks.ToList()) { blocks.Remove(block); earlier.Add(block); }
                else messages.Add(message);
            }
        }
        return messages;
    }
}

/// <summary>Messages typed while Claude is still replying; the remote task refuses a second send, so the client holds them.</summary>
public sealed class SendQueue
{
    public sealed record Item(string Id, string Text);
    private readonly List<Item> items = [];
    public IReadOnlyList<Item> Items => items;
    /// <summary>Set after a failed or stopped reply, so queued messages are not sent into a broken state without the user asking.</summary>
    public bool Paused { get; private set; }

    public Item Add(string text) { var item = new Item(Guid.NewGuid().ToString(), text); items.Add(item); return item; }
    public bool Cancel(string id) => items.RemoveAll(item => item.Id == id) > 0;
    /// <summary>Takes a message out of the queue to send it now or to edit it, or null when it has already gone.</summary>
    public Item? Take(string id)
    {
        var item = items.Find(queued => queued.Id == id);
        if (item is not null) items.Remove(item);
        if (items.Count == 0) Paused = false;
        return item;
    }
    /// <summary>Puts a message that could not be sent back at the head of the queue.</summary>
    public void Restore(Item item) => items.Insert(0, item);
    public void Pause() { if (items.Count > 0) Paused = true; }
    public void Resume() => Paused = false;
    public void Clear() { items.Clear(); Paused = false; }

    /// <summary>The next message to send once the reply has finished, or null.</summary>
    public Item? Next(bool busy)
    {
        if (busy || Paused || items.Count == 0) return null;
        var item = items[0]; items.RemoveAt(0); return item;
    }
}

/// <summary>A conversation as one piece of text, so a selection can run across messages.</summary>
public static class Transcript
{
    public sealed record Entry(bool User, string Text);
    /// <summary>The messages that have text, in order; tool calls and thinking are left out.</summary>
    public static List<Entry> Entries(IEnumerable<(bool User, string Text)> messages) =>
        messages.Where(message => !string.IsNullOrWhiteSpace(message.Text)).Select(message => new Entry(message.User, message.Text.Trim())).ToList();
    public static string Speaker(bool user) => user ? "你" : "Claude";
    public static string Text(IEnumerable<(bool User, string Text)> messages) =>
        string.Join("\n\n", Entries(messages).Select(entry => Speaker(entry.User) + "：\n" + entry.Text));
}

/// <summary>What a task snapshot says about the turn in progress.</summary>
public static class Turn
{
    /// <param name="sending">A prompt is on its way: the control commands sent before it publish idle snapshots that must not count as the end of a reply.</param>
    /// <summary>The context window in use as "128k / 1M", or null when the server has not reported it.</summary>
    public static string? Context(JsonNode? state)
    {
        if (state?["context"] is not JsonObject context || Number(context["usedTokens"]) is not { } used || Number(context["maxTokens"]) is not { } max || max <= 0) return null;
        return Tokens(used) + " / " + Tokens(max);
    }
    private static double? Number(JsonNode? node) => node is JsonValue value && value.TryGetValue<double>(out var number) ? number : null;
    public static string Tokens(double count) => count switch
    {
        >= 999_950 => (count / 1_000_000).ToString("0.#", System.Globalization.CultureInfo.InvariantCulture) + "M",
        >= 1000 => Math.Round(count / 1000).ToString("0", System.Globalization.CultureInfo.InvariantCulture) + "k",
        _ => Math.Round(Math.Max(0, count)).ToString("0", System.Globalization.CultureInfo.InvariantCulture)
    };
    public static bool Busy(JsonNode? state, bool sending) =>
        sending || state?["status"]?.GetValue<string>() is "working" or "connecting" or "permission" or "stopping";
    public static bool NeedsAnswer(JsonNode? state) =>
        state?["status"]?.GetValue<string>() == "permission" || state?["permissions"] is JsonArray { Count: > 0 };
    /// <summary>The reply failed or was stopped, so queued prompts wait for the user.</summary>
    public static bool Failed(JsonNode? state) =>
        state?["message"]?["error"] is not null || state?["message"]?["interrupted"]?.GetValue<bool>() == true;

    /// <summary>A label for a conversation that is not on screen, or null when there is nothing to say.</summary>
    public static string? Label(bool busy, bool needsAnswer, bool paused, int queued, bool unread) =>
        needsAnswer ? "等你确认" : busy ? (queued > 0 ? $"回复中 · 排队 {queued}" : "回复中") : paused ? $"已暂停 · 排队 {queued}" : unread ? "有新回复" : null;
}
