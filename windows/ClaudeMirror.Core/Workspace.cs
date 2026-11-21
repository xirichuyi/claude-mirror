using System.Text.RegularExpressions;

namespace ClaudeMirror.Core;

/// <summary>One line of a side-by-side diff. A changed line has both sides; an added or removed one has only its own.</summary>
public sealed record SplitRow(DiffKind Kind, int? LeftLine, string? Left, int? RightLine, string? Right);

public static partial class Workspace
{
    /// <summary>The letter and description shown for a `git status --porcelain` code.</summary>
    public static (string Letter, string Label) Status(string code)
    {
        var xy = code.PadRight(2);
        if (xy == "??") return ("U", "未跟踪");
        if (xy == "!!") return ("I", "已忽略");
        if (xy[0] == 'U' || xy[1] == 'U' || xy is "AA" or "DD") return ("!", "有冲突");
        char mark = xy[1] != ' ' ? xy[1] : xy[0];
        return mark switch
        {
            'M' => ("M", "已修改"), 'A' => ("A", "新增"), 'D' => ("D", "已删除"), 'R' => ("R", "已重命名"), 'C' => ("C", "已复制"), 'T' => ("T", "类型变更"),
            _ => (mark.ToString(), "已更改")
        };
    }

    /// <summary>Unified diff text as side-by-side rows. Removed and added runs within a hunk are paired line by line.</summary>
    public static List<SplitRow> Split(string unified)
    {
        var rows = new List<SplitRow>(); var removed = new List<(int Line, string Text)>(); var added = new List<(int Line, string Text)>();
        int left = 0, right = 0; bool inside = false;
        void Flush()
        {
            for (int i = 0; i < Math.Max(removed.Count, added.Count); i++)
            {
                bool hasLeft = i < removed.Count, hasRight = i < added.Count;
                rows.Add(new SplitRow(hasLeft ? DiffKind.Removed : DiffKind.Added, hasLeft ? removed[i].Line : null, hasLeft ? removed[i].Text : null, hasRight ? added[i].Line : null, hasRight ? added[i].Text : null));
            }
            removed.Clear(); added.Clear();
        }
        foreach (var raw in unified.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (HunkHeader().Match(line) is { Success: true } hunk)
            {
                Flush(); inside = true; left = int.Parse(hunk.Groups[1].Value); right = int.Parse(hunk.Groups[2].Value);
                rows.Add(new SplitRow(DiffKind.Hunk, null, line, null, null));
            }
            else if (line.StartsWith("Binary files ", StringComparison.Ordinal)) { Flush(); rows.Add(new SplitRow(DiffKind.Hunk, null, "二进制文件，无法显示差异", null, null)); }
            else if (!inside || line.StartsWith('\\')) continue;
            else if (line.StartsWith("diff --git ", StringComparison.Ordinal)) { Flush(); inside = false; }
            else if (line.StartsWith('-')) removed.Add((left++, line[1..]));
            else if (line.StartsWith('+')) added.Add((right++, line[1..]));
            else if (line.StartsWith(' ')) { Flush(); rows.Add(new SplitRow(DiffKind.Context, left++, line[1..], right++, line[1..])); }
        }
        Flush();
        return rows;
    }

    [GeneratedRegex(@"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")]
    private static partial Regex HunkHeader();
}
