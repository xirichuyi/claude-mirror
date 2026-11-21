using Xunit;
using System.Text.Json.Nodes;
using ClaudeMirror.Core;

namespace ClaudeMirror.Tests;

public class PermissionModesTests
{
    [Fact]
    public void FullAccessIsOfferedAndAutoOnlyWhenTheModelSupportsIt()
    {
        Assert.Contains(PermissionModes.For(false), mode => mode.Value == "bypassPermissions");
        Assert.DoesNotContain(PermissionModes.For(false), mode => mode.Value == "auto");
        Assert.Contains(PermissionModes.For(true), mode => mode.Value == "auto");
        Assert.Equal("Full Access", PermissionModes.Label("bypassPermissions"));
    }

    [Fact]
    public void ServerStatusSaysWhetherRootNeedsAnAccount()
    {
        var root = FullAccessStatus.From(JsonNode.Parse("""{"fullAccessAvailable":false,"requiresExecutionUser":true,"executionUser":"root"}"""));
        Assert.False(root.Available); Assert.True(root.NeedsAccount); Assert.Equal("root", root.Account);
        var runner = FullAccessStatus.From(JsonNode.Parse("""{"fullAccessAvailable":true,"requiresExecutionUser":false,"executionUser":"claude-runner"}"""));
        Assert.True(runner.Available); Assert.False(runner.NeedsAccount);
        Assert.False(FullAccessStatus.From(null).Available);
    }

    [Fact]
    public void ExecutionAccountIsChosenOnlyBeforeTheConversationStarts()
    {
        Assert.Equal("claude-runner", PermissionModes.ExecutionAccount(" claude-runner ", false, ""));
        Assert.Equal("claude-runner", PermissionModes.ExecutionAccount("claude-runner", true, "claude-runner"));
        Assert.Throws<IOException>(() => PermissionModes.ExecutionAccount("claude-runner", true, ""));
        Assert.Throws<IOException>(() => PermissionModes.ExecutionAccount("Bad Name", false, ""));
        Assert.Equal("", PermissionModes.ExecutionAccount("", false, ""));
    }

    [Fact]
    public void ExecutionAccountsAreRememberedPerHost()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var state = new LocalState(folder);
        state.RememberAccount("root@a:22", "claude-runner"); state.RememberAccount("root@a:22", "claude-runner"); state.RememberAccount("root@a:22", "");
        state.Save();
        Assert.Equal(["claude-runner"], new LocalState(folder).Accounts["root@a:22"]);
        Directory.Delete(folder, true);
    }
}
