using System.Globalization;
using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Xunit;

public class StatusSummaryTests
{
    public StatusSummaryTests() => CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

    [Fact]
    public void PluginsAreListedWithWhatTheServerReports()
    {
        var state = JsonNode.Parse("""{"plugins":[{"name":"superpowers","path":"/home/dev/.claude/plugins/superpowers","source":"marketplace","version":"1.2.0"},{"name":"bare"},"legacy",{"path":"/no/name"}]}""");
        var plugins = StatusSummary.Plugins(state);
        Assert.Equal(["superpowers", "bare", "legacy"], plugins.Select(plugin => plugin.Name));
        Assert.Equal("v1.2.0 · marketplace · /home/dev/.claude/plugins/superpowers", plugins[0].Detail);
        Assert.Null(plugins[1].Detail);
        Assert.Empty(StatusSummary.Plugins(JsonNode.Parse("{}")));
        Assert.Empty(StatusSummary.Plugins(null));
    }

    [Fact]
    public void AgentsAreListedWithTheirDescriptionAndModel()
    {
        var capabilities = JsonNode.Parse("""{"agents":[{"name":"code-reviewer","description":"Reviews a diff","model":"opus"},{"name":"general-purpose"},{"description":"nameless"}]}""");
        var agents = StatusSummary.Agents(capabilities);
        Assert.Equal(["code-reviewer", "general-purpose"], agents.Select(agent => agent.Name));
        Assert.Equal("Reviews a diff · 模型 opus", agents[0].Detail);
        Assert.Null(agents[1].Detail);
        Assert.Empty(StatusSummary.Agents(null));
    }

    [Fact]
    public void UsageShowsTheLastTurnTheCostAndEachModel()
    {
        var usage = JsonNode.Parse("""
            {"totalCostUSD":0.12345,"durationMs":83500,
             "lastTurn":{"input_tokens":1200,"output_tokens":345,"cache_read_input_tokens":50000,"cache_creation_input_tokens":1000},
             "models":{"claude-opus-4":{"inputTokens":2400,"outputTokens":700,"cacheReadInputTokens":90000,"costUSD":0.1},"claude-haiku-4":{"inputTokens":10,"outputTokens":5}}}
            """);
        var lines = StatusSummary.Usage(usage);
        Assert.Equal(["最近一轮", "远端报告费用", "claude-opus-4", "claude-haiku-4"], lines.Select(line => line.Name));
        Assert.Equal("输入 1,200（另有缓存 51,000） · 输出 345 tokens · 用时 1 分 23 秒", lines[0].Detail);
        Assert.StartsWith("$0.1235", lines[1].Detail);
        Assert.Equal("输入 2,400 · 输出 700 tokens · 读缓存 90,000 · $0.1000", lines[2].Detail);
        Assert.Equal("输入 10 · 输出 5 tokens", lines[3].Detail);
        Assert.Empty(StatusSummary.Usage(null));
        Assert.Empty(StatusSummary.Usage(JsonNode.Parse("""{"message":"尚无用量数据"}""")));
    }
}
