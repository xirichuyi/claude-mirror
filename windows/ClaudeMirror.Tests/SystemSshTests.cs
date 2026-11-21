using System.Net.Sockets;
using ClaudeMirror.Core;
using Xunit;

/// Runs against the sshd started by test-sshd.sh; skipped without it.
public sealed class SystemSshFactAttribute : FactAttribute
{
    public SystemSshFactAttribute()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CLAUDE_MIRROR_TEST_SSH_CONFIG")))
            Skip = "Start test-sshd.sh and set CLAUDE_MIRROR_TEST_SSH_CONFIG (and CLAUDE_MIRROR_TEST_RESOURCES) for the system SSH tests";
    }
}

public class SystemSshTests
{
    private static string Config => Environment.GetEnvironmentVariable("CLAUDE_MIRROR_TEST_SSH_CONFIG")!;
    private static string Resources => Environment.GetEnvironmentVariable("CLAUDE_MIRROR_TEST_RESOURCES")!;
    private static HostProfile Host(string alias) => new(alias, alias, 0, "", SystemSsh: true);

    [Fact]
    public void ArgumentsNeverPromptAndLeaveEmptyPartsToTheSshConfig()
    {
        var plain = SystemSsh.Arguments(Host("dev"), "echo hi");
        Assert.Contains("BatchMode=yes", plain); Assert.Contains("ClearAllForwardings=yes", plain);
        Assert.DoesNotContain("-p", plain); Assert.DoesNotContain("-l", plain); Assert.DoesNotContain("-J", plain);
        Assert.Equal(["--", "dev", "echo hi"], plain[^3..]);
        var full = SystemSsh.Arguments(new HostProfile("x", "10.0.0.5", 2200, "me", "C:\\keys\\id", true, "ops@bastion:2222,inner"), "echo hi");
        Assert.Equal(["-i", "C:\\keys\\id", "-J", "ops@bastion:2222,inner", "-p", "2200", "-l", "me", "--", "10.0.0.5", "echo hi"], full[^11..]);
    }

    [Fact]
    public void AForwardListensOnLoopbackOnlyAndAJumpHostNeedsNoLocalPort()
    {
        var forward = SystemSsh.Arguments(Host("dev") with { Jump = "bastion" }, null, new Tunnel(8080, 3000));
        Assert.Contains("127.0.0.1:8080:127.0.0.1:3000", forward); Assert.Contains("ExitOnForwardFailure=yes", forward); Assert.Contains("-N", forward);
        Assert.DoesNotContain("ClearAllForwardings=yes", forward);
        // A jump host is reached with -J alone: no -L or -D relay is added for it.
        var jumped = SystemSsh.Arguments(Host("dev") with { Jump = "bastion" }, "true");
        Assert.DoesNotContain("-L", jumped); Assert.DoesNotContain("-D", jumped); Assert.DoesNotContain("-W", jumped);
    }

    [Theory]
    [InlineData("-oProxyCommand=calc")]
    [InlineData("host name")]
    [InlineData("host;rm")]
    [InlineData("")]
    public void ValuesThatOpenSshCouldReadAsOptionsAreRefused(string host)
    {
        Assert.Throws<ArgumentException>(() => SystemSsh.Arguments(Host(host), "true"));
        Assert.Throws<ArgumentException>(() => SystemSsh.Arguments(Host("dev") with { Jump = host.Length == 0 ? "-J" : host }, "true"));
        Assert.Throws<ArgumentException>(() => SystemSsh.Arguments(Host("dev"), "-oProxyCommand=calc"));
    }

    [Fact]
    public void FailuresSayWhatToDo()
    {
        Assert.Equal(SystemSshFailure.HostKey, SystemSsh.Explain("No ED25519 host key is known for [127.0.0.1]:2222 and you have requested strict checking.\nHost key verification failed.").Kind);
        Assert.Equal(SystemSshFailure.HostKey, SystemSsh.Explain("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nHost key verification failed.").Kind);
        Assert.Equal(SystemSshFailure.Login, SystemSsh.Explain("me@host: Permission denied (publickey).").Kind);
        var other = SystemSsh.Explain("ssh: Could not resolve hostname nowhere: Name or service not known\n");
        Assert.Equal(SystemSshFailure.Other, other.Kind); Assert.Contains("Could not resolve hostname", other.Message);
        Assert.Equal("ssh -J bastion -p 2200 -l me 10.0.0.5", SystemSsh.TerminalCommand(new HostProfile("x", "10.0.0.5", 2200, "me", null, true, "bastion")));
    }

    [SystemSshFact]
    public async Task AnUntrustedHostKeyIsRefusedWithoutPrompting()
    {
        using var agent = new RemoteAgent();
        var failure = await Assert.ThrowsAsync<SystemSshException>(() => agent.ConnectSystemAsync(Host("mirror-unknown"), Resources, Config));
        Assert.Equal(SystemSshFailure.HostKey, failure.Kind);
    }

    [SystemSshTheory]
    [InlineData("mirror-target")]
    [InlineData("mirror-jumped")]
    public async Task TheAgentRunsOverSystemSshDirectlyAndThroughAJumpHost(string alias)
    {
        using var agent = new RemoteAgent();
        await agent.ConnectSystemAsync(Host(alias), Resources, Config);
        Assert.True(agent.Connected); Assert.StartsWith("/", agent.Home);
        Assert.NotNull((await agent.CallAsync("history", new { operation = "list", offset = 0 }))["sessions"]);
        Assert.Equal("a b\n", await agent.RunScriptAsync("printf '%s\\n' 'a b'"));

        // Bytes survive both directions unchanged.
        var folder = Directory.CreateTempSubdirectory("mirror-ssh-").FullName;
        var source = Path.Combine(folder, "payload 文件.bin"); var copy = Path.Combine(folder, "copy.bin");
        var bytes = new byte[300_000]; new Random(7).NextBytes(bytes); await File.WriteAllBytesAsync(source, bytes);
        var remote = await agent.UploadAsync(source);
        await agent.DownloadAsync(remote, copy);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(copy));
        await Assert.ThrowsAsync<IOException>(() => agent.DownloadAsync("/nonexistent/file", copy));

        // A forwarded port reaches the server's loopback: here, the test sshd itself.
        var target = int.Parse(File.ReadLines(Path.Combine(Path.GetDirectoryName(Config)!, "sshd_config")).First(line => line.StartsWith("Port ")).Split(' ')[1]);
        var local = target + 1000 + (alias.Length % 2);
        await agent.ForwardAsync(new Tunnel(local, target));
        using (var client = new TcpClient())
        {
            await client.ConnectAsync("127.0.0.1", local);
            var banner = new byte[4]; await client.GetStream().ReadExactlyAsync(banner);
            Assert.Equal("SSH-", System.Text.Encoding.ASCII.GetString(banner));
        }
        await Assert.ThrowsAsync<IOException>(() => agent.ForwardAsync(new Tunnel(local, target)));
        agent.CloseForward(local);
        Directory.Delete(folder, true);
    }

    [SystemSshFact]
    public async Task ALostChannelIsReported()
    {
        using var agent = new RemoteAgent();
        var lost = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        agent.Disconnected += message => lost.TrySetResult(message);
        await agent.ConnectSystemAsync(Host("mirror-target"), Resources, Config);
        // The agent process on the server ends, as it does when the network drops.
        await agent.RunScriptAsync("pkill -f 'remotecc/agent/.*/remote-agent[.]cjs'");
        Assert.Contains("SSH", await lost.Task.WaitAsync(TimeSpan.FromSeconds(30)));
        Assert.False(agent.Connected);
    }
}

public sealed class SystemSshTheoryAttribute : TheoryAttribute
{
    public SystemSshTheoryAttribute()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CLAUDE_MIRROR_TEST_SSH_CONFIG"))) Skip = "Needs test-sshd.sh";
    }
}
