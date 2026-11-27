using System.Text.Json.Nodes;

namespace ClaudeMirror.Core;

/// <summary>The remote agent could not start because the server lacks a usable Node.js.</summary>
public sealed class RemoteSetupException(bool outdated, string? version = null)
    : IOException(outdated ? $"服务器上的 Node.js {version} 太旧，需要 18.14 或更新版本。" : "服务器上没有 Node.js（需要 18.14 或更新版本）。")
{
    public bool Outdated { get; } = outdated;
    public string? Version { get; } = version;
}

public enum HealthAction { None, Install, Login, Copy }

/// <summary>One setup problem on the server and the fix the app can offer.</summary>
public sealed record HealthIssue(string Kind, string Title, string Detail, HealthAction Action, string? Command, bool Blocking);

public static class MachineHealth
{
    /// <summary>Mirrors the macOS checklist: Node.js, Claude Code, Claude login, background persistence.</summary>
    public static List<HealthIssue> Issues(Exception? startError, JsonNode? hello, JsonNode? status)
    {
        var issues = new List<HealthIssue>();
        if (startError is RemoteSetupException setup)
        {
            issues.Add(new("node", setup.Outdated ? $"服务器的 Node.js {setup.Version} 太旧" : "服务器缺少 Node.js",
                "安装到用户目录，不需要管理员权限",
                HealthAction.Install, null, true));
            return issues;
        }
        if (hello is null) return issues;
        var claude = status is not null ? status["claude"]?.GetValue<string>() : hello["claude"]?.GetValue<string>();
        if (claude is null)
            issues.Add(new("claude", "服务器还没有安装 Claude Code", "安装到用户目录", HealthAction.Install, null, true));
        else if (status?["auth"]?.GetValue<string>() == "loggedOut")
            issues.Add(new("login", "服务器上的 Claude Code 还没有登录", "在终端登录后重新检查",
                HealthAction.Login, status["loginCommand"]?.GetValue<string>() ?? "claude auth login", true));
        if (hello["persistenceWarning"]?.GetValue<string>() is { } warning)
            issues.Add(new("persistence", "断开连接后回复会中断", warning, HealthAction.Copy, "loginctl enable-linger", false));
        return issues;
    }
}

/// <summary>Turns SSH failures into what a new user can act on; unknown messages pass through.</summary>
public static class ConnectionAdvice
{
    private static readonly (string[] Patterns, string Advice)[] Rules =
    [
        (["permission denied", "authentication failed", "no suitable authentication"], "服务器拒绝了登录：用户名、密码或密钥不正确"),
        (["too many authentication failures"], "密钥尝试次数过多，请指定私钥或改用密码"),
        (["no such host is known", "could not resolve hostname", "name or service not known"], "找不到这个服务器地址"),
        (["actively refused", "connection refused"], "服务器拒绝连接，检查 SSH 端口"),
        (["timed out", "did not properly respond", "within the specified time", "established within"], "连接超时"),
        (["network is unreachable", "no route to host"], "网络不通：请检查网络连接或 VPN。"),
        (["主机指纹发生变化", "host key"], "服务器的身份指纹已变化"),
        (["connection reset", "forcibly closed", "connection closed by"], "服务器在登录前断开"),
    ];

    public static string Explain(string message)
    {
        var trimmed = message.Trim();
        if (trimmed.Contains("原始信息：")) return trimmed;
        var lower = trimmed.ToLowerInvariant();
        foreach (var (patterns, advice) in Rules)
            if (patterns.Any(lower.Contains)) return advice + "\n原始信息：" + trimmed.Split('\n').Last();
        return trimmed;
    }
}

public sealed record RemoteMember(string Name, string Fingerprint);

/// <summary>Accounts on a shared server, managed through install-claude-remote.sh from a root login.</summary>
public static class RemoteMembers
{
    public static string Command(params string[] arguments) =>
        "sh -c " + Protocol.Quote("command -v bash >/dev/null 2>&1 || exit 1; exec bash -s -- " + string.Join(" ", arguments.Select(Protocol.Quote)) + " 2>&1");

    public static List<RemoteMember> Parse(IEnumerable<string> lines) =>
        lines.Select(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            .Where(parts => parts.Length >= 3 && parts[0] == "member")
            .Select(parts => new RemoteMember(parts[1], parts[2] == "-" ? "" : parts[2])).ToList();
}

public static class RemoteInstaller
{
    public const string Command = "sh -c 'command -v bash >/dev/null 2>&1 || { echo \"服务器缺少 bash，无法自动安装。\"; exit 1; }; exec bash -s 2>&1'";
    /// <summary>Only puts Node.js on the server; the agent runs this by itself when Node.js is missing or too old.</summary>
    public const string NodeCommand = "sh -c 'command -v bash >/dev/null 2>&1 || exit 1; exec bash -s -- --node-only 2>&1'";

    public static string Summary(int code) => code switch
    {
        0 => "安装完成，正在重新检查服务器…",
        3 => "Node.js 未能安装，请手动安装 18.14+",
        _ => $"安装失败（退出码 {code}）",
    };

    /// <summary>Adds a public key to the server's authorized_keys once, keeping existing lines.</summary>
    public static string AuthorizeScript(string publicKey)
    {
        var line = publicKey.Trim() + " claude-mirror";
        return string.Join("\n",
            "umask 077",
            "F=\"$HOME/.ssh/authorized_keys\"",
            "mkdir -p \"$HOME/.ssh\" && chmod 700 \"$HOME/.ssh\" && touch \"$F\" && chmod 600 \"$F\" || exit 1",
            "K=" + Protocol.Quote(line),
            "if [ -s \"$F\" ] && [ -n \"$(tail -c 1 \"$F\")\" ]; then echo >> \"$F\"; fi",
            "grep -qxF \"$K\" \"$F\" || printf '%s\\n' \"$K\" >> \"$F\" || exit 1",
            "echo __RCC_KEY_OK__");
    }

    /// <summary>Returns "ssh-ed25519 &lt;base64&gt;" or null.</summary>
    public static string? ValidPublicKey(string text)
    {
        var parts = text.Split([' ', '\n', '\r', '\t'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || parts[0] != "ssh-ed25519" || parts[1].Length < 60) return null;
        return parts[1].All(c => char.IsAsciiLetterOrDigit(c) || c is '+' or '/' or '=') ? "ssh-ed25519 " + parts[1] : null;
    }
}
