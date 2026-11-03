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
    }
}
