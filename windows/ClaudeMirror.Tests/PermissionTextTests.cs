using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Xunit;

namespace ClaudeMirror.Tests;

public class PermissionTextTests
{
    [Fact] public void SuggestionsReadAsPlainLanguage()
    {
        var lines = PermissionText.RuleLines(JsonNode.Parse("""
            [{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"},
             {"type":"setMode","mode":"acceptEdits","destination":"session"},
             {"type":"removeRules","rules":[{"toolName":"WebFetch"}],"behavior":"deny","destination":"userSettings"}]
            """));
        Assert.Equal(new[] { "自动允许 Bash(npm test:*)", "权限模式切换为「自动接受编辑」", "移除规则 WebFetch" }, lines.Select(l => l.Action));
        Assert.Equal(new[] { "此项目的本地设置", "本次运行", "远端用户的所有项目" }, lines.Select(l => l.Scope));
        Assert.Equal(new[] { true, true, false }, lines.Select(l => l.Widens));
        Assert.Empty(PermissionText.RuleLines(null));
    }

    [Fact] public void TitleAndSummaryShowWhatRuns()
    {
        var bash = JsonNode.Parse("""{"name":"Bash","input":{"command":"swift test"}}""")!;
        Assert.Equal("Claude 请求使用 Bash", PermissionText.Title(bash));
        Assert.Equal(("命令", "swift test"), PermissionText.Summary(bash));
        Assert.Equal("Claude 想确认几个问题", PermissionText.Title(JsonNode.Parse("""{"name":"AskUserQuestion"}""")!));
    }

    [Fact] public void AnswerKeepsLabelsWithCommas()
    {
        Assert.Equal("Red, bright, Blue, and green", PermissionText.Answer(["Red, bright", "Blue"], "  and green "));
        Assert.Equal("", PermissionText.Answer([], "  "));
    }
}
