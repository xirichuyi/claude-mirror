using ClaudeMirror.Core;
using Xunit;

public sealed class ReviewCommentTests
{
    [Fact]
    public void RowsPickTheirNewSideOrTheDeletedLine()
    {
        var rows = Workspace.Split("@@ -1,3 +1,3 @@\n keep\n-old line\n+new line\n-gone\n");
        var changed = rows.First(r => r.Right == "new line");
        Assert.Equal(new ReviewComment("/p/a.ts", 2, false, "new line", "改名"), ReviewComment.For(changed, "/p/a.ts", " 改名 \n"));
        var deleted = rows.First(r => r.Left == "gone");
        Assert.Equal(new ReviewComment("/p/a.ts", 3, true, "gone", "为什么删"), ReviewComment.For(deleted, "/p/a.ts", "为什么删"));
        Assert.Null(ReviewComment.For(rows[0], "/p/a.ts", "x"));
        Assert.Null(ReviewComment.For(changed, "/p/a.ts", "  "));
    }

    [Fact]
    public void PromptListsCommentsInFileOrder()
    {
        var text = ReviewComment.Prompt([new("/p/b.ts", 1, false, "b()", "第二"), new("/p/a.ts", 9, true, "  gone()", "第一\n两行")], "/p");
        Assert.Equal("请按下面的评论修改代码：\n\n1. `a.ts 删除前第 9 行`\n   > gone()\n   第一\n   两行\n\n2. `b.ts:1`\n   > b()\n   第二", text);
        Assert.Equal("/other/x", ReviewComment.Relative("/other/x", "/p"));
    }
}
