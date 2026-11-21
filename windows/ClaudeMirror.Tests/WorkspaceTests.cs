using ClaudeMirror.Core;
using Xunit;

public class WorkspaceTests
{
    [Fact]
    public void SplitPairsChangedLinesAndKeepsLineNumbers()
    {
        var rows = Workspace.Split("""
            diff --git a/app.js b/app.js
            index 111..222 100644
            --- a/app.js
            +++ b/app.js
            @@ -10,4 +10,5 @@ function start() {
             const a = 1;
            -const b = 2;
            -const c = 3;
            +const b = 20;
            +const c = 30;
            +const d = 40;
             return a;
            \ No newline at end of file
            """.Replace("\n            ", "\n").TrimStart());
        Assert.Equal(DiffKind.Hunk, rows[0].Kind);
        Assert.Equal(new SplitRow(DiffKind.Context, 10, "const a = 1;", 10, "const a = 1;"), rows[1]);
        Assert.Equal(new SplitRow(DiffKind.Removed, 11, "const b = 2;", 11, "const b = 20;"), rows[2]);
        Assert.Equal(new SplitRow(DiffKind.Removed, 12, "const c = 3;", 12, "const c = 30;"), rows[3]);
        Assert.Equal(new SplitRow(DiffKind.Added, null, null, 13, "const d = 40;"), rows[4]);
        Assert.Equal(new SplitRow(DiffKind.Context, 13, "return a;", 14, "return a;"), rows[5]);
        Assert.Equal(6, rows.Count);
    }

    [Fact]
    public void SplitHandlesNewFilesAndBinaryFiles()
    {
        var created = Workspace.Split("diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+one\n+two\n");
        Assert.Equal([(int?)1, 2], created.Skip(1).Select(row => row.RightLine));
        Assert.All(created.Skip(1), row => Assert.Null(row.Left));
        Assert.Equal("二进制文件，无法显示差异", Assert.Single(Workspace.Split("diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n")).Left);
        Assert.Empty(Workspace.Split(""));
    }

    [Theory]
    [InlineData("??", "U")] [InlineData(" M", "M")] [InlineData("M ", "M")] [InlineData("A ", "A")] [InlineData(" D", "D")]
    [InlineData("R ", "R")] [InlineData("UU", "!")] [InlineData("AA", "!")] [InlineData("AM", "M")]
    public void StatusLetters(string code, string letter) => Assert.Equal(letter, Workspace.Status(code).Letter);
}
