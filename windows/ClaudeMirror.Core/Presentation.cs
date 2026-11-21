using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeMirror.Core;

public enum DiffKind { Context, Added, Removed, Hunk }
public sealed record DiffRow(DiffKind Kind, string Text);
public sealed record TodoItem(string Text, string Status);
public enum ToolBodyKind { None, Command, Code, Diff, Todos, Markdown }

/// <summary>How one tool call reads best, independent of the UI toolkit. Mirrors the macOS client's ToolPresentation.</summary>
public sealed class ToolPresentation
{
    public string Title { get; }
    public string? Subject { get; }
    public string? File { get; }
    public int? Line { get; }
    public ToolBodyKind Body { get; }
    public string Text { get; } = "";
    public IReadOnlyList<DiffRow> Diff { get; } = [];
    public IReadOnlyList<TodoItem> Todos { get; } = [];
    public bool StartsOpen { get; }
    public bool HidesOutput { get; }

    public ToolPresentation(string? name, JsonNode? input)
    {
        var fields = input as JsonObject ?? [];
        string? Field(string key) => Presentation.Text(fields[key]);
        Title = name ?? "工具";
        switch (name)
        {
            case "Bash":
                Subject = Field("description") ?? Presentation.FirstLine(Field("command"));
                Body = ToolBodyKind.Command; Text = Field("command") ?? "";
                break;
            case "Read":
                File = Field("file_path"); Line = fields["offset"] is JsonValue offset && offset.TryGetValue<int>(out var line) ? line : null;
                Subject = Line is null ? null : $"第 {Line} 行起";
                break;
            case "Write":
                File = Field("file_path"); Text = Field("content") ?? "";
                Subject = $"{(Text.Length == 0 ? 0 : Text.Split('\n').Length)} 行";
                Body = ToolBodyKind.Code; HidesOutput = true;
                break;
            case "Edit" or "MultiEdit":
                Title = "Edit"; File = Field("file_path");
                var edits = fields["edits"] as JsonArray;
                if (edits is not null) Subject = $"{edits.Count} 处";
                Diff = edits is not null
                    ? edits.SelectMany(edit => Presentation.LineDiff(Presentation.Text(edit?["old_string"]) ?? "", Presentation.Text(edit?["new_string"]) ?? "")).ToList()
                    : Presentation.LineDiff(Field("old_string") ?? "", Field("new_string") ?? "");
                Body = ToolBodyKind.Diff; StartsOpen = true; HidesOutput = true;
                break;
            case "NotebookEdit":
                File = Field("notebook_path"); Body = ToolBodyKind.Code; Text = Field("new_source") ?? "";
                break;
            case "Grep" or "Glob":
                Subject = Field("pattern") is { } pattern ? Field("path") is { } path ? pattern + " · " + path : pattern : null;
                break;
            case "LS":
                File = Field("path");
                break;
            case "WebFetch":
                Subject = Field("url");
                if (Field("prompt") is { } fetch) { Body = ToolBodyKind.Code; Text = fetch; }
                break;
            case "WebSearch":
                Subject = Field("query");
                break;
            case "TodoWrite":
                Title = "任务清单";
                Todos = (fields["todos"] as JsonArray ?? []).Select(item =>
                {
                    var status = Presentation.Text(item?["status"]) ?? "pending";
                    var text = status == "in_progress" ? Presentation.Text(item?["activeForm"]) ?? Presentation.Text(item?["content"]) : Presentation.Text(item?["content"]);
                    return new TodoItem(text ?? "", status);
                }).ToList();
                Subject = $"{Todos.Count(todo => todo.Status == "completed")}/{Todos.Count}";
                Body = ToolBodyKind.Todos; StartsOpen = true; HidesOutput = true;
                break;
            case "ExitPlanMode":
                Title = "计划";
                if (Field("plan") is { } plan) { Body = ToolBodyKind.Markdown; Text = plan; }
                StartsOpen = true; HidesOutput = true;
                break;
            case "AskUserQuestion":
                Title = "提问";
                Subject = fields["questions"] is JsonArray questions ? string.Join(" · ", questions.Select(q => Presentation.Text(q?["question"])).Where(q => q is not null)) : null;
                break;
            case "Skill":
                Subject = Field("skill") ?? Field("command");
                break;
            case "Task" or "Agent":
                Title = Field("subagent_type") is { } type ? "Agent · " + type : "Agent";
                Subject = Field("description");
                if (Field("prompt") is { } prompt) { Body = ToolBodyKind.Code; Text = prompt; }
                break;
            default:
                if (name?.StartsWith("mcp__") == true)
                {
                    var parts = name[5..].Split("__");
                    if (parts.Length >= 2) Title = parts[0] + " · " + string.Join("__", parts[1..]);
                }
                Subject = Presentation.FirstLine(fields.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => Presentation.Text(pair.Value)).FirstOrDefault(value => value is not null));
                if (fields.Count > 0) { Body = ToolBodyKind.Code; Text = fields.ToJsonString(Presentation.Pretty); }
                break;
        }
    }
}

public static class Presentation
{
    internal static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>The node's value when it is a JSON string.</summary>
    public static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    public static string? FirstLine(string? text, int limit = 90)
    {
        var line = text?.Split('\n')[0];
        if (string.IsNullOrEmpty(line)) return null;
        return line.Length > limit ? line[..limit] + "…" : line;
    }

    /// <summary>A tool's output as text: a string, or the text parts of a content array.</summary>
    public static string Output(JsonNode? output) => output switch
    {
        null => "",
        JsonValue value when value.TryGetValue<string>(out var text) => text,
        JsonArray parts => string.Join("\n", parts.Select(part => Text(part?["text"]) ?? (Text(part?["type"]) == "image" ? "[图片]" : part?.ToJsonString(Pretty)))),
        _ => output.ToJsonString(Pretty)
    };

    /// <summary>Longest common subsequence over lines, with two lines of context; very large edits fall back to remove-all/add-all.</summary>
    public static List<DiffRow> LineDiff(string before, string after)
    {
        var a = before.Split('\n'); var b = after.Split('\n');
        int start = 0;
        while (start < a.Length && start < b.Length && a[start] == b[start]) start++;
        int endA = a.Length, endB = b.Length;
        while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) { endA--; endB--; }
        var middleA = a[start..endA]; var middleB = b[start..endB];
        var rows = a[Math.Max(0, start - 2)..start].Select(line => new DiffRow(DiffKind.Context, line)).ToList();
        if ((long)middleA.Length * middleB.Length > 250_000)
        {
            rows.AddRange(middleA.Select(line => new DiffRow(DiffKind.Removed, line)));
            rows.AddRange(middleB.Select(line => new DiffRow(DiffKind.Added, line)));
        }
        else
        {
            int width = middleB.Length + 1;
            var table = new int[(middleA.Length + 1) * width];
            for (int i = middleA.Length - 1; i >= 0; i--)
                for (int j = middleB.Length - 1; j >= 0; j--)
                    table[i * width + j] = middleA[i] == middleB[j] ? table[(i + 1) * width + j + 1] + 1 : Math.Max(table[(i + 1) * width + j], table[i * width + j + 1]);
            int x = 0, y = 0;
            while (x < middleA.Length || y < middleB.Length)
            {
                if (x < middleA.Length && y < middleB.Length && middleA[x] == middleB[y]) { rows.Add(new(DiffKind.Context, middleA[x])); x++; y++; }
                else if (y < middleB.Length && (x == middleA.Length || table[x * width + y + 1] > table[(x + 1) * width + y])) rows.Add(new(DiffKind.Added, middleB[y++]));
                else rows.Add(new(DiffKind.Removed, middleA[x++])); // Ties remove first, the way diffs are usually read.
            }
        }
        rows.AddRange(a[endA..Math.Min(a.Length, endA + 2)].Select(line => new DiffRow(DiffKind.Context, line)));
        return rows;
    }
}
