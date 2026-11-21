using System.Net.Sockets;
using ClaudeMirror.Core;
using Xunit;

/// Runs against the sshd started by test-sshd.sh; skipped without it.
public sealed class SystemSshFactAttribute : FactAttribute
{
    /// <param name="agent">The test starts the remote agent, which needs a Unix server and CLAUDE_MIRROR_TEST_RESOURCES.</param>
    public SystemSshFactAttribute(bool agent = false) { Skip = SystemSshTests.Missing(agent); }
}

public class SystemSshTests
{
    private static string Config => Environment.GetEnvironmentVariable("CLAUDE_MIRROR_TEST_SSH_CONFIG")!;
    private static string Resources => Environment.GetEnvironmentVariable("CLAUDE_MIRROR_TEST_RESOURCES")!;
    private static HostProfile Host(string alias) => new(alias, alias, 0, "", SystemSsh: true);
    internal static string? Missing(bool agent) =>
        string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CLAUDE_MIRROR_TEST_SSH_CONFIG")) ? "Start test-sshd.sh (or test-sshd.ps1) and set CLAUDE_MIRROR_TEST_SSH_CONFIG for the system SSH tests"
        : agent && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CLAUDE_MIRROR_TEST_RESOURCES")) ? "Set CLAUDE_MIRROR_TEST_RESOURCES to a prepared server folder for the remote agent tests" : null;
    private static int ServerPort => int.Parse(File.ReadLines(Path.Combine(Path.GetDirectoryName(Config)!, "sshd_config")).First(line => line.StartsWith("Port ")).Split(' ')[1]);

    [Fact]
    public void TheSameAddressBehindTwoJumpHostsIsTwoServers()
    {
        var direct = new HostProfile("a", "10.0.0.5", 22, "root");
        var first = direct with { SystemSsh = true, Jump = "ops@bastion-a" };
        var second = direct with { SystemSsh = true, Jump = "ops@bastion-b" };
        Assert.Equal("root@10.0.0.5:22", LocalState.HostKey(direct)); // Saved state from before jump hosts keeps its key.
        Assert.Equal(LocalState.HostKey(direct), LocalState.HostKey(direct with { SystemSsh = true }));
        Assert.NotEqual(LocalState.HostKey(first), LocalState.HostKey(second));
        Assert.NotEqual(LocalState.HostKey(direct), LocalState.HostKey(first));
    }

    /// The installed OpenSSH client reads every option this app passes. `ssh -G` parses the command line and prints the result without connecting,
    /// so this runs against the real ssh.exe on a Windows build machine.
    [Fact]
    public async Task TheInstalledSshClientAcceptsTheseArguments()
    {
        var profile = new HostProfile("x", "target.example", 2200, "me", null, true, "ops@bastion.example:2222");
        foreach (var arguments in new[] { SystemSsh.Arguments(profile, "echo hi"), SystemSsh.Arguments(profile, null, new Tunnel(18080, 3000)), SystemSsh.Arguments(Host("alias"), "echo hi") })
        {
            var info = new System.Diagnostics.ProcessStartInfo(SystemSsh.Executable()) { RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, UseShellExecute = false };
            info.ArgumentList.Add("-G"); foreach (var argument in arguments) info.ArgumentList.Add(argument);
            System.Diagnostics.Process process;
            try { process = System.Diagnostics.Process.Start(info)!; } catch (System.ComponentModel.Win32Exception) { return; } // No OpenSSH client on this machine.
            process.StandardInput.Close();
            var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            Assert.True(process.ExitCode == 0, await error);
            var settings = (await output).ToLowerInvariant();
            Assert.Contains("batchmode yes", settings);
            Assert.Contains(arguments.Contains("alias") ? "hostname alias" : "hostname target.example", settings);
            if (!arguments.Contains("alias")) { Assert.Contains("proxyjump ops@bastion.example:2222", settings); Assert.Contains("port 2200", settings); Assert.Contains("user me", settings); }
        }
    }

    /// The transport alone, without the remote agent: bytes both ways, exit codes, errors, and a forwarded port.
    [SystemSshTheory]
    [InlineData("mirror-target")]
    [InlineData("mirror-jumped")]
    public async Task ACommandCarriesBytesBothWaysAndReportsItsExit(string alias)
    {
        using var link = new SystemSshLink(Host(alias), Config);
        var bytes = new byte[200_000]; new Random(11).NextBytes(bytes);
        using (var echo = link.Run("cat", true, CancellationToken.None))
        {
            var received = new MemoryStream(); var reading = echo.Output.CopyToAsync(received);
            using (var input = echo.Input) await input.WriteAsync(bytes);
            Assert.Equal(0, await echo.Exit.WaitAsync(TimeSpan.FromSeconds(60))); await reading;
            Assert.Equal(bytes, received.ToArray());
        }
        using (var failing = link.Run("echo problem >&2; exit 7", false, CancellationToken.None))
        {
            Assert.Equal(7, await failing.Exit.WaitAsync(TimeSpan.FromSeconds(60)));
            Assert.Contains("problem", failing.Error);
        }
        using var cancel = new CancellationTokenSource();
        using (var waiting = link.Run("sleep 600", false, cancel.Token))
        {
            cancel.Cancel();
            await waiting.Exit.WaitAsync(TimeSpan.FromSeconds(30)); // Cancelling ends the ssh process instead of leaving it behind.
        }
        int local = ServerPort + 2000 + (alias.Length % 2);
        using (var forward = link.Forward(new Tunnel(local, ServerPort)))
        {
            using var client = new TcpClient(); await client.ConnectAsync("127.0.0.1", local);
            var banner = new byte[4]; await client.GetStream().ReadExactlyAsync(banner);
            Assert.Equal("SSH-", System.Text.Encoding.ASCII.GetString(banner));
            Assert.True(forward.Alive);
        }
    }

    [SystemSshFact]
    public async Task AnUntrustedHostKeyFailsACommandWithoutPrompting()
    {
        using var link = new SystemSshLink(Host("mirror-unknown"), Config);
        using var run = link.Run("echo should-not-run", false, CancellationToken.None);
        using var reader = new StreamReader(run.Output); var output = reader.ReadToEndAsync();
        Assert.NotEqual(0, await run.Exit.WaitAsync(TimeSpan.FromSeconds(60)));
        Assert.DoesNotContain("should-not-run", await output);
        Assert.Equal(SystemSshFailure.HostKey, SystemSsh.Explain(run.Error).Kind);
    }

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

    [SystemSshFact(agent: true)]
    public async Task AnUntrustedHostKeyIsRefusedWithoutPrompting()
    {
        using var agent = new RemoteAgent();
        var failure = await Assert.ThrowsAsync<SystemSshException>(() => agent.ConnectSystemAsync(Host("mirror-unknown"), Resources, Config));
        Assert.Equal(SystemSshFailure.HostKey, failure.Kind);
    }

    [SystemSshTheory(agent: true)]
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
        var target = ServerPort;
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

    [SystemSshFact(agent: true)]
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
    public SystemSshTheoryAttribute(bool agent = false) { Skip = SystemSshTests.Missing(agent); }
}
