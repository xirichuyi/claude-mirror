using System.Text.Json.Nodes;

namespace ClaudeMirror.Core;

/// <summary>One suggested permission update in words; same wording as the macOS card.</summary>
public sealed record PermissionRuleLine(string Action, string Scope, bool Widens);

/// <summary>Plain-language text for a permission request, instead of showing its JSON.</summary>
public static class PermissionText
{
    private static readonly Dictionary<string, string> Scopes = new()
    {
        ["session"] = "本次运行", ["localSettings"] = "此项目的本地设置", ["projectSettings"] = "此项目的共享设置",
        ["userSettings"] = "远端用户的所有项目", ["cliArg"] = "本次启动参数",
    };
    private static readonly Dictionary<string, string> Modes = new()
    {
        ["default"] = "默认", ["acceptEdits"] = "自动接受编辑", ["bypassPermissions"] = "跳过所有确认", ["plan"] = "计划模式", ["dontAsk"] = "不再询问",
    };

    private static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    public static IReadOnlyList<PermissionRuleLine> RuleLines(JsonNode? suggestions) =>
        suggestions is JsonArray list ? list.Where(item => item is not null).Select(item => Line(item!)).ToList() : [];

    private static PermissionRuleLine Line(JsonNode update)
    {
        var destination = Text(update["destination"]) ?? "";
        var scope = Scopes.GetValueOrDefault(destination, destination);
        var rules = string.Join("、", (update["rules"] as JsonArray ?? []).Select(rule =>
        {
            var tool = Text(rule?["toolName"]) ?? "工具";
            var content = Text(rule?["ruleContent"]);
            return string.IsNullOrEmpty(content) ? tool : $"{tool}({content})";
        }));
        var directories = string.Join("、", (update["directories"] as JsonArray ?? []).Select(Text).OfType<string>());
        var behavior = Text(update["behavior"]);
        var verb = behavior == "deny" ? "始终拒绝" : behavior == "ask" ? "始终询问" : "自动允许";
        switch (Text(update["type"]))
        {
            case "addRules": return new($"{verb} {rules}", scope, behavior == "allow");
            case "replaceRules": return new($"改为{verb} {rules}", scope, behavior == "allow");
            case "removeRules": return new($"移除规则 {rules}", scope, false);
            case "setMode":
                var mode = Text(update["mode"]) ?? "";
                return new($"权限模式切换为「{Modes.GetValueOrDefault(mode, mode)}」", scope, mode is "acceptEdits" or "bypassPermissions" or "dontAsk");
            case "addDirectories": return new($"允许访问目录 {directories}", scope, true);
            case "removeDirectories": return new($"移除目录 {directories}", scope, false);
            default: return new(update.ToJsonString(), scope, true);
        }
    }

    /// <summary>Dialog title for a request.</summary>
    public static string Title(JsonNode permission) => Text(permission["name"]) switch
    {
        _ when Text(permission["kind"]) == "elicitation" => Text(permission["request"]?["title"]) ?? "需要你的输入",
        "AskUserQuestion" => "Claude 想确认几个问题",
        "ExitPlanMode" => "Claude 的计划，确认后开始执行",
        var name => Text(permission["title"]) ?? $"Claude 请求使用 {name ?? "工具"}",
    };

    /// <summary>The part of the tool input worth reading before approving: the command, the file, the URL…</summary>
    public static (string? Label, string? Body) Summary(JsonNode permission)
    {
        var input = permission["input"];
        string? Field(string key) => Text(input?[key]);
        return Text(permission["name"]) switch
        {
            "Bash" => ("命令", Field("command")),
            "Edit" or "MultiEdit" or "Write" or "Read" or "NotebookEdit" => ("文件", Field("file_path") ?? Field("notebook_path")),
            "WebFetch" => ("网址", Field("url")),
            "WebSearch" => ("搜索", Field("query")),
            "Glob" or "Grep" => ("查找", Field("pattern")),
            "ExitPlanMode" => (null, Field("plan")),
            _ => (null, input?.ToJsonString(new() { WriteIndented = true })),
        };
    }

    /// <summary>AskUserQuestion answer: picked option labels, then any typed text, comma-joined as the SDK expects.</summary>
    public static string Answer(IEnumerable<string> picked, string? typed)
    {
        var text = typed?.Trim() ?? "";
        return string.Join(", ", picked.Concat(text.Length > 0 ? new[] { text } : Array.Empty<string>()));
    }
}

/// <summary>What the server said about running Claude without confirmations (the inspect action <c>permissionStatus</c>).</summary>
public sealed record FullAccessStatus(bool Available, bool NeedsAccount, string Account)
{
    public static FullAccessStatus From(JsonNode? status) => new(
        status?["fullAccessAvailable"]?.GetValue<bool>() == true,
        status?["requiresExecutionUser"]?.GetValue<bool>() == true,
        status?["executionUser"]?.GetValue<string>() ?? "");
}

public static class PermissionModes
{
    public const string FullAccess = "bypassPermissions";
    public static readonly (string Value, string Label, string Hint)[] All =
    [
        ("default", "默认权限", "每次操作前询问"), ("plan", "计划", "只制定计划，不修改文件"),
        ("acceptEdits", "自动编辑", "自动接受文件编辑"), ("dontAsk", "拒绝未授权", "未授权的操作直接拒绝"),
        (FullAccess, "Full Access", "跳过操作确认"), ("auto", "自动权限", "由 Claude 判断是否需要确认")
    ];
    /// <summary>The modes to offer. Auto is listed only when the chosen model reports support for it.</summary>
    public static IEnumerable<(string Value, string Label, string Hint)> For(bool autoSupported) =>
        All.Where(mode => mode.Value != "auto" || autoSupported);
    public static string Label(string value) => All.FirstOrDefault(mode => mode.Value == value).Label ?? value;
    /// <summary>The account name Claude runs as, or an error. The account can only be chosen before the conversation starts.</summary>
    public static string ExecutionAccount(string? typed, bool conversationStarted, string current)
    {
        var name = (typed ?? "").Trim();
        if (name == current) return name;
        if (conversationStarted) throw new IOException("执行账号会改变登录与历史记录的位置，请新建对话后再选择");
        if (name.Length > 0 && !System.Text.RegularExpressions.Regex.IsMatch(name, "^[a-z_][a-z0-9_-]{0,31}$")) throw new IOException("执行账号只能是服务器上的普通用户名，例如 claude-runner");
        return name;
    }
}
