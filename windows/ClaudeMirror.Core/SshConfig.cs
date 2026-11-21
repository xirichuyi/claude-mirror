namespace ClaudeMirror.Core;

/// <summary>The parts of an OpenSSH client config this app uses: Host patterns with HostName, User, Port and IdentityFile. ProxyJump is read only to say that the host needs a jump host, which this client does not connect through.</summary>
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
            var line = WithoutComment(raw).Trim();
            if (line.Length == 0) continue;
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

    /// <summary>A line up to a `#` that starts it or follows whitespace outside quotes, as OpenSSH reads it.</summary>
    private static string WithoutComment(string line)
    {
        bool quoted = false;
        for (int i = 0; i < line.Length; i++)
        {
            if (line[i] == '"') quoted = !quoted;
            else if (line[i] == '#' && !quoted && (i == 0 || char.IsWhiteSpace(line[i - 1]))) return line[..i];
        }
        return line;
    }

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
