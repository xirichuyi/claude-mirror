using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Xunit;

public class PresentationTests
{
    private static JsonNode Json(string text) => JsonNode.Parse(text)!;

    [Fact]
    public void EditBecomesADiffWithRemovedLinesFirst()
    {
        var edit = new ToolPresentation("Edit", Json("""{"file_path":"/a.js","old_string":"a\nb\nc","new_string":"a\nB\nc"}"""));
        Assert.Equal("/a.js", edit.File); Assert.True(edit.StartsOpen); Assert.True(edit.HidesOutput);
        Assert.Equal([new(DiffKind.Context, "a"), new(DiffKind.Removed, "b"), new(DiffKind.Added, "B"), new(DiffKind.Context, "c")], edit.Diff);
        var multi = new ToolPresentation("MultiEdit", Json("""{"file_path":"/a.js","edits":[{"old_string":"x","new_string":"y"},{"old_string":"1","new_string":"2"}]}"""));
        Assert.Equal("Edit", multi.Title); Assert.Equal("2 处", multi.Subject); Assert.Equal(4, multi.Diff.Count);
    }

    [Fact]
    public void DiffKeepsTwoLinesOfContextAndHandlesPureInsertions()
    {
        var rows = Presentation.LineDiff("1\n2\n3\n4\n5\n6\n7", "1\n2\n3\nnew\n4\n5\n6\n7");
        Assert.Equal(["2", "3", "new", "4", "5"], rows.Select(row => row.Text));
        Assert.Equal(DiffKind.Added, rows[2].Kind);
        Assert.DoesNotContain(Presentation.LineDiff("same", "same"), row => row.Kind != DiffKind.Context);
    }

    [Fact]
    public void ToolsGetReadableTitlesAndSubjects()
    {
        Assert.Equal("gh · list_prs", new ToolPresentation("mcp__gh__list_prs", Json("""{"q":"v"}""")).Title);
        Assert.Equal("Agent · Explore", new ToolPresentation("Task", Json("""{"subagent_type":"Explore","description":"d"}""")).Title);
        Assert.Equal("constructor", new ToolPresentation("constructor", null).Title);
        Assert.Equal("doing", new ToolPresentation("TodoWrite", Json("""{"todos":[{"content":"x","activeForm":"doing","status":"in_progress"}]}""")).Todos[0].Text);
        var bash = new ToolPresentation("Bash", Json("""{"command":"npm test\nnpm run lint"}"""));
        Assert.Equal("npm test", bash.Subject); Assert.Equal(ToolBodyKind.Command, bash.Body); Assert.False(bash.HidesOutput);
        Assert.Equal("refresh\\( · src", new ToolPresentation("Grep", Json("""{"pattern":"refresh\\(","path":"src"}""")).Subject);
        Assert.Equal("第 40 行起", new ToolPresentation("Read", Json("""{"file_path":"/a","offset":40}""")).Subject);
        Assert.Equal("a\n[图片]", Presentation.Output(Json("""[{"type":"text","text":"a"},{"type":"image"}]""")));
    }

    [Fact]
    public void HistoryJoinsToolResultsAndMergesAReplySplitAcrossRecords()
    {
        var records = Json("""
        [
          {"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"<system-reminder>x</system-reminder>\n改一下"}]}},
          {"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"想"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}},
          {"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"boom","is_error":true}]}},
          {"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"完成"}]}},
          {"type":"user","uuid":"u3","message":{"content":[{"type":"text","text":"<command-name>/compact</command-name><command-args>now</command-args>"}]}},
          {"type":"user","uuid":"u4","message":{"content":[{"type":"text","text":"<local-command-stdout>Compacted</local-command-stdout>"}]}},
          {"type":"assistant","uuid":"a3","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error"}]}}
        ]
        """).AsArray();
        var messages = History.Messages(records);
        Assert.Equal(["user", "assistant", "user", "assistant", "assistant"], messages.Select(m => m["role"]!.GetValue<string>()));
        Assert.Equal("改一下", messages[0]["text"]!.GetValue<string>());
        var blocks = messages[1]["blocks"]!.AsArray();
        Assert.Equal(["thinking", "tool", "text"], blocks.Select(b => b!["type"]!.GetValue<string>()));
        Assert.Equal("error", blocks[1]!["status"]!.GetValue<string>()); Assert.Equal("boom", blocks[1]!["output"]!.GetValue<string>());
        Assert.Equal("/compact now", messages[2]["text"]!.GetValue<string>());
        Assert.Equal("command", messages[3]["blocks"]![0]!["format"]!.GetValue<string>());
        Assert.Equal("API Error", messages[4]["error"]!.GetValue<string>());
    }

    [Fact]
    public void QueueHoldsMessagesUntilTheReplyEndsAndPausesAfterAFailure()
    {
        var queue = new SendQueue();
        var first = queue.Add("one"); queue.Add("two");
        Assert.Null(queue.Next(busy: true));
        Assert.Equal("one", queue.Next(busy: false)!.Text);
        queue.Pause();
        Assert.Null(queue.Next(busy: false));
        queue.Resume();
        Assert.False(queue.Cancel(first.Id));
        Assert.True(queue.Cancel(queue.Items[0].Id));
        Assert.Null(queue.Next(busy: false));
        queue.Pause(); Assert.False(queue.Paused);
    }
}
