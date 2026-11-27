using System.Text;
using ClaudeMirror.Core;
using Xunit;

namespace ClaudeMirror.Tests;

public class ConnectionCodeTests
{
    private const string HostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJicQEkLt46JTOUutsQxgSDR9f2KuTIuIlLprFr65vfd";
    private const string PrivateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----";
    private static readonly string[] Valid = ["claude-mirror 1", "name box", "host 203.0.113.5", "port 2222", "user alice", "hostkey " + HostKey, PrivateKey];
    private static string Code(IEnumerable<string> lines) =>
        "cm1." + Convert.ToBase64String(Encoding.UTF8.GetBytes(string.Join("\n", lines) + "\n")).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    [Fact] public void ParsesWhatTheServerPrints()
    {
        var code = ConnectionCode.Parse("  " + Code(Valid) + "\r\n");
        Assert.Equal(("box", "203.0.113.5", 2222, "alice"), (code.Name, code.Host, code.Port, code.User));
        Assert.Equal(PrivateKey + "\n", code.PrivateKey);
        Assert.StartsWith("SHA256:", Assert.Single(code.HostKeyFingerprints));
        Assert.Equal(50, code.HostKeyFingerprints[0].Length);
        Assert.Contains("'ssh-ed25519 AAAA claude-mirror'", ConnectionCode.ClaimScript("ssh-ed25519 AAAA\n"));
    }

    [Fact] public void RejectsCodesThatCouldNotLogInSafely()
    {
        Assert.Throws<IOException>(() => ConnectionCode.Parse("cm2.abc"));
        Assert.Throws<IOException>(() => ConnectionCode.Parse(Code(Valid.Where(l => !l.StartsWith("hostkey")))));
        Assert.Throws<IOException>(() => ConnectionCode.Parse(Code(Valid.Select(l => l == "user alice" ? "user a;b" : l))));
        Assert.Throws<IOException>(() => ConnectionCode.Parse(Code(Valid.Select(l => l == "host 203.0.113.5" ? "host -oProxyCommand" : l))));
        Assert.Throws<IOException>(() => ConnectionCode.Parse(Code(new[] { "claude-mirror 2" }.Concat(Valid.Skip(1)))));
    }
}
