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
}
