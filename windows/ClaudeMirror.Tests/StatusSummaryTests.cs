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
}
