using ClaudeMirror.Core;
using Xunit;

public class SshConfigTests
{
    [Fact]
    public void ReadsAliasesWithWildcardDefaultsAndFirstValueWins()
    {
        var entries = SshConfig.Parse("""
            # work machines
            Host build
              HostName 10.0.0.8
              User ci
              Port 2222
              IdentityFile ~/.ssh/id_build
              ProxyJump bastion
            Host bastion gate
              HostName=bastion.example.com
            Host *.internal !secret.internal
              User ops
            Host *
              User fallback
              IdentityFile "~/.ssh/id_ed25519"
            """, "/home/me");
        Assert.Equal(["build", "bastion", "gate"], entries.Select(entry => entry.Alias));
        var build = entries[0];
        Assert.Equal(("10.0.0.8", "ci", 2222, Path.Combine("/home/me", ".ssh/id_build"), "bastion"), (build.Host, build.User, build.Port, build.KeyFile, build.ProxyJump));
        Assert.Equal(("bastion.example.com", "fallback", 22), (entries[1].Host, entries[1].User, entries[1].Port));
        Assert.Null(entries[1].ProxyJump);
    }

    [Fact]
    public void JumpHostsAreReadFromAddressesAndAliases()
    {
        var plain = SshConfig.Jump("ops@gate.example.com:2200", "me", "/keys/id");
        Assert.Equal(("gate.example.com", 2200, "ops", "/keys/id"), (plain.Host, plain.Port, plain.User, plain.KeyFile));
        Assert.Equal(("gate", 22, "me"), (SshConfig.Jump("gate", "me", null).Host, SshConfig.Jump("gate", "me", null).Port, SshConfig.Jump("gate", "me", null).User));
        var known = SshConfig.Parse("Host bastion\n  HostName 10.1.1.1\n  User jump\n  Port 2022\n  IdentityFile /keys/bastion", "/home/me");
        var alias = SshConfig.Jump("bastion", "me", "/keys/id", known);
        Assert.Equal(("10.1.1.1", 2022, "jump", "/keys/bastion"), (alias.Host, alias.Port, alias.User, alias.KeyFile));
        Assert.Equal("jump@10.1.1.1:2022", SshConfig.JumpSpec(alias));
        Assert.Equal(plain with { Name = "x" }, SshConfig.Jump(SshConfig.JumpSpec(plain), "other", "/keys/id") with { Name = "x" });
        Assert.Throws<ArgumentException>(() => SshConfig.Jump("a,b", "me", null));
        Assert.Throws<ArgumentException>(() => SshConfig.Jump("gate:0", "me", null));
    }

    [Fact]
    public void ForwardingNeedsValidPortsAndAConnection()
    {
        using var agent = new RemoteAgent();
        Assert.Throws<ArgumentException>(() => agent.Forward(new Tunnel(0, 3000)));
        Assert.Throws<ArgumentException>(() => agent.Forward(new Tunnel(3000, 70000)));
        Assert.Throws<IOException>(() => agent.Forward(new Tunnel(3000, 3000)));
        Assert.Empty(agent.Tunnels);
        agent.CloseForward(3000);
    }
}
