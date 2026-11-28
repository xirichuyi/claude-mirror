namespace ClaudeMirror.Core;

/// <summary>A note on one line of a diff, collected until the user sends them all to Claude at once.</summary>
public sealed record ReviewComment(string Path, int Line, bool Removed, string Code, string Text)
{
    /// <summary>The comment for a diff row, on its new side when it has one; null for hunk headers or empty text.</summary>
    public static ReviewComment? For(SplitRow row, string path, string text)
    {
        var body = text.Trim();
        if (row.Kind == DiffKind.Hunk || body.Length == 0) return null;
        if (row.RightLine is { } right) return new(path, right, false, row.Right ?? "", body);
        if (row.LeftLine is { } left) return new(path, left, true, row.Left ?? "", body);
        return null;
    }

    public string Location(string? root)
    {
        var shown = Relative(Path, root);
        return Removed ? $"{shown} 删除前第 {Line} 行" : $"{shown}:{Line}";
    }

    public static string Relative(string path, string? root)
    {
        if (string.IsNullOrEmpty(root)) return path;
        var prefix = root.EndsWith('/') ? root : root + "/";
        return path.StartsWith(prefix, StringComparison.Ordinal) ? path[prefix.Length..] : path;
    }

    /// <summary>One message asking Claude to address every comment, in file and line order.</summary>
    public static string Prompt(IEnumerable<ReviewComment> comments, string? root)
    {
        var lines = new List<string> { "请按下面的评论修改代码：" };
        var index = 0;
        foreach (var comment in comments.OrderBy(c => c.Path, StringComparer.Ordinal).ThenBy(c => c.Line).ThenBy(c => c.Removed ? 0 : 1))
        {
            lines.Add("");
            lines.Add($"{++index}. `{comment.Location(root)}`");
            var code = comment.Code.Trim(' ', '\t');
            if (code.Length > 0) lines.Add("   > " + code);
            lines.AddRange(comment.Text.Split('\n').Select(part => "   " + part));
        }
        return string.Join("\n", lines);
    }
}
