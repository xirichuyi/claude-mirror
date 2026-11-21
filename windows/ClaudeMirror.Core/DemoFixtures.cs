using System.Text.Json.Nodes;

namespace ClaudeMirror.Core;

public static class DemoFixtures
{
    /// <summary>The bundled demo data: answers keyed by "op.operation" or "op.operation:key".</summary>
    public static JsonObject Load()
    {
        using var stream = typeof(DemoFixtures).Assembly.GetManifestResourceStream("Demo.json")!;
        return JsonNode.Parse(stream)!.AsObject();
    }
}
