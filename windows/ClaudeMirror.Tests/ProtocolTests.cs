using ClaudeMirror.Core;
using System.Text.Json.Nodes;
using Xunit;

public class ProtocolTests
{
    [Fact] public void DeltaAppendsTextAndAddsBlocksWithoutMutatingSnapshot()
    {
        var initial = JsonNode.Parse("""{"version":1,"message":{"blocks":[{"text":"你"}]}}""")!.AsObject();
        var delta = JsonNode.Parse("""{"delta":true,"base":1,"version":2,"patches":[{"path":["version"],"value":2},{"path":["message","blocks",0,"text"],"append":"好"},{"path":["message","blocks",1],"value":{"type":"tool","name":"Read"}}]}""")!.AsObject();
        var result = Protocol.Apply(initial, delta);
        Assert.Equal("你好", result["message"]!["blocks"]![0]!["text"]!.GetValue<string>());
        Assert.Equal(2, result["message"]!["blocks"]!.AsArray().Count);
        Assert.Equal("你", initial["message"]!["blocks"]![0]!["text"]!.GetValue<string>());
    }
    [Fact] public void RejectsOutOfOrderState() => Assert.Throws<InvalidDataException>(() => Protocol.Apply(null, JsonNode.Parse("""{"delta":true,"base":1,"version":2}""")!.AsObject()));
    [Fact] public void QuotePreservesApostropheWithoutShellExpansion() => Assert.Equal("'a'\\''$(touch x)'", Protocol.Quote("a'$(touch x)"));
    [Fact] public void PersistsHostAndRecoveryMetadata()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var local = new LocalState(folder); local.Hosts.Add(new("开发", "example.org", 2222, "alice")); local.Tasks["task"] = "id"; local.Save();
            var restored = new LocalState(folder); Assert.Equal(2222, restored.Hosts[0].Port); Assert.Equal("id", restored.Tasks["task"]);
            Assert.DoesNotContain("password", File.ReadAllText(Path.Combine(folder, "state.json")), StringComparison.OrdinalIgnoreCase);
        }
        finally { Directory.Delete(folder, true); }
    }    [Fact] public void ReadsHostsSavedWithAJumpHost()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "state.json"), """{"hosts":[{"Name":"内网","Host":"10.0.0.8","Port":22,"User":"ci","KeyFile":"/keys/id","ProxyJump":"ops@gate:22","JumpKeyFile":"/keys/gate"}]}""");
            var host = Assert.Single(new LocalState(folder).Hosts);
            Assert.Equal(("10.0.0.8", "ci", "/keys/id"), (host.Host, host.User, host.KeyFile));
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public void TheLoginShellStartsInTheProjectOrAtHome()
    {
        Assert.Equal("sh -c 'cd -- \"$1\" 2>/dev/null || cd; exec \"${SHELL:-/bin/sh}\" -l' sh '/srv/my app'", LoginShell.Command("/srv/my app"));
        Assert.Equal("\"$HOME\"'/it'\\''s'", LoginShell.Folder("~/it's"));
        Assert.Equal("\"$HOME\"", LoginShell.Folder("~"));
        Assert.StartsWith(" exec sh -c 'clear; cd -- ", LoginShell.Typed("/srv"));
        if (OperatingSystem.IsWindows()) return;
        var home = Directory.CreateTempSubdirectory("mirror-home-").FullName;
        var project = Directory.CreateDirectory(Path.Combine(home, "it's a dir")).FullName;
        string Pwd(string directory)
        {
            var info = new System.Diagnostics.ProcessStartInfo("/bin/sh") { RedirectStandardInput = true, RedirectStandardOutput = true };
            info.ArgumentList.Add("-c"); info.ArgumentList.Add(LoginShell.Command(directory));
            info.Environment["HOME"] = home; info.Environment["SHELL"] = "/bin/sh";
            using var shell = System.Diagnostics.Process.Start(info)!;
            shell.StandardInput.WriteLine("pwd"); shell.StandardInput.Close();
            var output = shell.StandardOutput.ReadToEnd().Trim(); shell.WaitForExit(); return output;
        }
        Assert.Equal(project, Pwd("~/it's a dir"));
        Assert.Equal(project, Pwd(project));
        Assert.Equal(home, Pwd("/nonexistent/folder"));
    }
}
