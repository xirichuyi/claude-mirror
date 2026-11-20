namespace ClaudeMirror.Core;

/// <summary>The parts of an OpenSSH client config this app uses: Host patterns with HostName, User, Port, IdentityFile and ProxyJump.</summary>
public static class SshConfig
{
    public sealed record Entry(string Alias, string Host, string? User, int Port, string? KeyFile, string? ProxyJump);

    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "config");

    /// <summary>Concrete aliases (no wildcards) with the settings that apply to them; the first value found wins, as in OpenSSH.</summary>
    public static List<Entry> Parse(string text, string home)
    {
        var blocks = new List<(string[] Patterns, Dictionary<string, string> Values)>();
        (string[] Patterns, Dictionary<string, string> Values) current = (["*"], new(StringComparer.OrdinalIgnoreCase));
        blocks.Add(current);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] == '#') continue;
            var split = line.IndexOfAny([' ', '\t', '=']);
            if (split < 0) continue;
            var key = line[..split]; var value = line[split..].TrimStart(' ', '\t', '=').Trim().Trim('"');
            if (key.Equals("Host", StringComparison.OrdinalIgnoreCase))
            {
                current = (value.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries), new(StringComparer.OrdinalIgnoreCase));
                blocks.Add(current);
            }
            else if (key.Equals("Match", StringComparison.OrdinalIgnoreCase)) { current = ([], new(StringComparer.OrdinalIgnoreCase)); blocks.Add(current); } // Not supported: its settings are ignored.
            else current.Values.TryAdd(key, value);
        }
        var entries = new List<Entry>();
        foreach (var alias in blocks.SelectMany(block => block.Patterns).Where(pattern => !pattern.Contains('*') && !pattern.Contains('?') && !pattern.StartsWith('!')).Distinct())
        {
            string? Value(string key) => blocks.Where(block => Matches(block.Patterns, alias)).Select(block => block.Values.GetValueOrDefault(key)).FirstOrDefault(value => value is not null);
            var key = Value("IdentityFile");
            if (key is not null) key = (key.StartsWith("~/") ? Path.Combine(home, key[2..]) : key).Replace("%d", home);
            var jump = Value("ProxyJump");
            entries.Add(new Entry(alias, Value("HostName") ?? alias, Value("User"), int.TryParse(Value("Port"), out var port) ? port : 22, key,
                jump is null || jump.Equals("none", StringComparison.OrdinalIgnoreCase) ? null : jump));
        }
        return entries;
    }

    /// <summary>The jump host named by a ProxyJump value: <c>[user@]host[:port]</c>, or an alias from <paramref name="known"/>. Chains of several hosts are not supported.</summary>
    public static HostProfile Jump(string spec, string defaultUser, string? keyFile, IEnumerable<Entry>? known = null)
    {
        var text = spec.Trim();
        if (text.Length == 0 || text.Contains(',') || text.Contains(' ')) throw new ArgumentException("跳板机请写成 用户名@主机:端口，目前只支持一台跳板机");
        if (text.StartsWith("ssh://", StringComparison.OrdinalIgnoreCase)) text = text[6..].TrimEnd('/');
        string? user = null; int port = 22;
        var at = text.LastIndexOf('@');
        if (at > 0) { user = text[..at]; text = text[(at + 1)..]; }
        var colon = text.LastIndexOf(':');
        if (colon > 0 && !text.EndsWith(']'))
        {
            if (!int.TryParse(text[(colon + 1)..], out port) || port is < 1 or > 65535) throw new ArgumentException("跳板机端口无效");
            text = text[..colon];
        }
        text = text.Trim('[', ']');
        if (text.Length == 0) throw new ArgumentException("跳板机请写成 用户名@主机:端口");
        if (known?.FirstOrDefault(entry => entry.Alias.Equals(text, StringComparison.OrdinalIgnoreCase)) is { } alias)
            return new HostProfile(alias.Alias, alias.Host, colon > 0 ? port : alias.Port, user ?? alias.User ?? defaultUser, alias.KeyFile ?? keyFile);
        return new HostProfile(text, text, port, user ?? defaultUser, keyFile);
    }

    /// <summary>A jump host in the form <see cref="Jump"/> reads back.</summary>
    public static string JumpSpec(HostProfile jump) => $"{jump.User}@{(jump.Host.Contains(':') ? "[" + jump.Host + "]" : jump.Host)}:{jump.Port}";

    private static bool Matches(string[] patterns, string alias)
    {
        bool matched = false;
        foreach (var pattern in patterns)
        {
            if (pattern.StartsWith('!')) { if (Glob(pattern[1..], alias)) return false; }
            else matched |= Glob(pattern, alias);
        }
        return matched;
    }

    private static bool Glob(string pattern, string text) =>
        System.Text.RegularExpressions.Regex.IsMatch(text, "^" + System.Text.RegularExpressions.Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
}
