using System.Text.Json.Nodes;
using ClaudeMirror.Core;
using Xunit;

namespace ClaudeMirror.Tests;

public class RemoteSetupTests
{
    [Fact] public void MissingNodeOffersInstallOnly()
    {
        var issues = MachineHealth.Issues(new RemoteSetupException(false), null, null);
        Assert.Single(issues); Assert.Equal("node", issues[0].Kind); Assert.Equal(HealthAction.Install, issues[0].Action);
        Assert.Contains("v16.0.0", MachineHealth.Issues(new RemoteSetupException(true, "v16.0.0"), null, null)[0].Title);
        Assert.Empty(MachineHealth.Issues(new IOException("other"), null, null));
    }

    [Fact] public void ClaudeLoginAndPersistenceChecklist()
    {
        var hello = JsonNode.Parse("""{"home":"/h","claude":"/c","persistenceWarning":"会中断"}""");
        Assert.Equal(new[] { "claude" }, MachineHealth.Issues(null, JsonNode.Parse("""{"home":"/h"}"""), null).Select(i => i.Kind));
        var issues = MachineHealth.Issues(null, hello, JsonNode.Parse("""{"claude":"/c","auth":"loggedOut","loginCommand":"/c auth login"}"""));
        Assert.Equal(new[] { "login", "persistence" }, issues.Select(i => i.Kind));
        Assert.Equal("/c auth login", issues[0].Command); Assert.False(issues[1].Blocking);
        Assert.Equal(new[] { "persistence" }, MachineHealth.Issues(null, hello, JsonNode.Parse("""{"claude":"/c","auth":"unknown"}""")).Select(i => i.Kind));
    }

    [Fact] public void ConnectionAdviceExplainsWindowsAndOpenSshFailures()
    {
        Assert.StartsWith("服务器拒绝了登录", ConnectionAdvice.Explain("Permission denied (password)."));
        Assert.StartsWith("找不到这个服务器地址", ConnectionAdvice.Explain("No such host is known."));
        Assert.StartsWith("服务器拒绝连接", ConnectionAdvice.Explain("No connection could be made because the target machine actively refused it."));
        Assert.Equal("something else", ConnectionAdvice.Explain(" something else "));
        var once = ConnectionAdvice.Explain("Permission denied");
        Assert.Equal(once, ConnectionAdvice.Explain(once));
    }

    [Fact] public void AuthorizeScriptQuotesKeyAndValidatesInput()
    {
        var key = "ssh-ed25519 " + new string('A', 68);
        Assert.Equal(key, RemoteInstaller.ValidPublicKey(key + " comment\n"));
        Assert.Null(RemoteInstaller.ValidPublicKey("ssh-rsa AAAA"));
        Assert.Null(RemoteInstaller.ValidPublicKey("ssh-ed25519 " + new string('A', 60) + "'$(x)"));
        Assert.Contains("K='" + key + " claude-mirror'", RemoteInstaller.AuthorizeScript(key));
    }
}
