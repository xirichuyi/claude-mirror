using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using Renci.SshNet;

namespace ClaudeMirror.Core;

/// <summary>One command on the server with its own input, output and exit status.</summary>
public interface IRemoteRun : IDisposable
{
    Stream Output { get; }
    /// <summary>The command's standard input; disposing it sends end-of-file. Empty unless the command was started with input.</summary>
    Stream Input { get; }
    Task<int> Exit { get; }
    string Error { get; }
}

/// <summary>A local port forwarded to the server's loopback until disposed.</summary>
public interface IForward : IDisposable { bool Alive { get; } }

/// <summary>How this app reaches a server: the built-in SSH library, or the computer's own OpenSSH client.</summary>
public interface ISshLink : IDisposable
{
    bool Connected { get; }
    IRemoteRun Run(string command, bool input, CancellationToken token);
    IForward Forward(Tunnel tunnel);
}

internal sealed class LibraryLink(SshClient ssh) : ISshLink
{
    public bool Connected => ssh.IsConnected;
    public IRemoteRun Run(string command, bool input, CancellationToken token) => new Command(ssh.CreateCommand(command), input, token);
    public IForward Forward(Tunnel tunnel)
    {
        var port = new ForwardedPortLocal("127.0.0.1", (uint)tunnel.LocalPort, "127.0.0.1", (uint)tunnel.RemotePort);
        ssh.AddForwardedPort(port);
        try { port.Start(); }
        catch (System.Net.Sockets.SocketException e)
        {
            ssh.RemoveForwardedPort(port); port.Dispose();
            throw new IOException($"无法监听本地端口 {tunnel.LocalPort}：{e.Message}", e);
        }
        return new Port(ssh, port);
    }
    public void Dispose() => ssh.Dispose();

    private sealed class Command : IRemoteRun
    {
        private readonly SshCommand command;
        public Command(SshCommand command, bool input, CancellationToken token)
        {
            this.command = command;
            var executing = command.ExecuteAsync(token);
            if (input) Input = command.CreateInputStream();
            Exit = FinishAsync(executing);
        }
        private async Task<int> FinishAsync(Task executing) { await executing; return command.ExitStatus ?? -1; }
        public Stream Output => command.OutputStream;
        public Stream Input { get; } = Stream.Null;
        public Task<int> Exit { get; }
        public string Error => command.Error;
        public void Dispose() => command.Dispose();
    }
    private sealed class Port(SshClient ssh, ForwardedPortLocal port) : IForward
    {
        public bool Alive => port.IsStarted;
        public void Dispose()
        {
            try { port.Stop(); ssh.RemoveForwardedPort(port); } catch (Exception e) when (e is ObjectDisposedException or Renci.SshNet.Common.SshException) { }
            port.Dispose();
        }
    }
}

public enum SystemSshFailure { HostKey, Login, Missing, Other }
public sealed class SystemSshException(SystemSshFailure kind, string message) : IOException(message)
{
    public SystemSshFailure Kind { get; } = kind;
}

/// <summary>
/// The computer's OpenSSH client (ssh.exe). It reads ~/.ssh/config, uses ssh-agent and known_hosts, and reaches a
/// server behind a jump host over the jump host's own SSH channel, so no relay port is opened on this computer.
/// It never prompts: logging in needs a key that works without typing, and unknown host keys are refused.
/// </summary>
public static class SystemSsh
{
    private static readonly System.Text.RegularExpressions.Regex Name = new("^[A-Za-z0-9_.@:%+\\[\\]-]+$");
    /// <summary>A host, user or jump value that OpenSSH cannot read as an option.</summary>
    public static bool Safe(string? value) => value is { Length: > 0 } && !value.StartsWith('-') && Name.IsMatch(value);
    /// <summary>One or more jump hosts separated by commas, as in <c>ssh -J</c>.</summary>
    public static bool SafeJump(string? value) => value is { Length: > 0 } && value.Split(',').All(Safe);

    public static string Executable()
    {
        if (Environment.GetEnvironmentVariable("CLAUDE_MIRROR_SSH") is { Length: > 0 } chosen) return chosen;
        var bundled = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");
        return OperatingSystem.IsWindows() && File.Exists(bundled) ? bundled : "ssh";
    }

    public static void Validate(HostProfile profile)
    {
        if (!Safe(profile.Host) || (profile.User.Length > 0 && !Safe(profile.User)) || profile.Port is < 0 or > 65535)
            throw new ArgumentException("请填写主机名或 SSH 别名");
        if (profile.Jump is { Length: > 0 } jump && !SafeJump(jump)) throw new ArgumentException("跳板机格式：user@host 或别名，逗号分隔");
    }

    /// <summary>Where to log in: jump host, port, user and host. Empty parts are left to the SSH config.</summary>
    public static List<string> Destination(HostProfile profile, string? config = null)
    {
        Validate(profile);
        var arguments = new List<string>();
        if (config is not null) { arguments.Add("-F"); arguments.Add(config); }
        if (profile.KeyFile is { Length: > 0 } key) { arguments.Add("-i"); arguments.Add(key); }
        if (profile.Jump is { Length: > 0 } jump) { arguments.Add("-J"); arguments.Add(jump); }
        if (profile.Port > 0) { arguments.Add("-p"); arguments.Add(profile.Port.ToString()); }
        if (profile.User.Length > 0) { arguments.Add("-l"); arguments.Add(profile.User); }
        arguments.Add("--"); arguments.Add(profile.Host);
        return arguments;
    }

    /// <summary>Arguments for a command that never prompts, or for a port forward when <paramref name="forward"/> is given.</summary>
    public static List<string> Arguments(HostProfile profile, string? command, Tunnel? forward = null, string? config = null)
    {
        if (command is not null && (command.Length == 0 || command.StartsWith('-'))) throw new ArgumentException("无效的远端命令");
        var arguments = new List<string> { "-T", "-a", "-x" };
        foreach (var option in new[] { "BatchMode=yes", "ConnectTimeout=20", "ServerAliveInterval=5", "ServerAliveCountMax=4", "ControlMaster=no", "ControlPath=none", "PermitLocalCommand=no", "LogLevel=ERROR" })
        { arguments.Add("-o"); arguments.Add(option); }
        if (forward is null) { arguments.Add("-o"); arguments.Add("ClearAllForwardings=yes"); }
        else
        {
            arguments.AddRange(["-N", "-o", "ExitOnForwardFailure=yes", "-L", $"127.0.0.1:{forward.LocalPort}:127.0.0.1:{forward.RemotePort}"]);
        }
        arguments.AddRange(Destination(profile, config));
        if (command is not null) arguments.Add(command);
        return arguments;
    }

    /// <summary>The same login typed by hand, where OpenSSH may ask about a host key or a passphrase.</summary>
    public static string TerminalCommand(HostProfile profile) =>
        "ssh " + string.Join(" ", Destination(profile).Where(part => part != "--").Select(part => part.Contains(' ') ? "\"" + part + "\"" : part));

    public static SystemSshException Explain(string error)
    {
        var text = error.Trim();
        if (text.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
            return new(SystemSshFailure.HostKey, "主机密钥与 known_hosts 不一致，已拒绝。确认后运行 ssh-keygen -R 再连接");
        if (text.Contains("Host key verification failed") || text.Contains("host key is known"))
            return new(SystemSshFailure.HostKey, "主机密钥未知，请先在终端里 ssh 一次");
        if (text.Contains("Permission denied"))
            return new(SystemSshFailure.Login, "服务器没有接受密钥，请先 ssh-add");
        var last = text.Split('\n').Select(line => line.Trim()).LastOrDefault(line => line.Length > 0);
        return new(SystemSshFailure.Other, "系统 SSH 连接失败" + (last is null ? "" : "：" + last));
    }
}

public sealed class SystemSshLink(HostProfile profile, string? config = null) : ISshLink
{
    private readonly ConcurrentDictionary<ProcessRun, bool> running = new();
    private volatile bool closed;
    public bool Connected => !closed;

    public IRemoteRun Run(string command, bool input, CancellationToken token) => Start(SystemSsh.Arguments(profile, command, null, config), input, token);

    public IForward Forward(Tunnel tunnel)
    {
        if (Listening(tunnel.LocalPort)) throw new IOException($"无法监听本地端口 {tunnel.LocalPort}：端口已被占用");
        var run = Start(SystemSsh.Arguments(profile, null, tunnel, config), false, CancellationToken.None);
        var deadline = DateTime.UtcNow.AddSeconds(45);
        while (!run.Exit.IsCompleted && !Listening(tunnel.LocalPort))
        {
            if (DateTime.UtcNow > deadline) { run.Dispose(); throw new IOException($"转发本地端口 {tunnel.LocalPort} 超时"); }
            Thread.Sleep(100);
        }
        if (!run.Exit.IsCompleted) return run;
        var error = run.Error; run.Dispose();
        throw new IOException($"无法转发本地端口 {tunnel.LocalPort}：" + SystemSsh.Explain(error).Message);
    }

    private static bool Listening(int port) =>
        System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Any(endpoint => endpoint.Port == port);

    private ProcessRun Start(List<string> arguments, bool input, CancellationToken token)
    {
        if (closed) throw new IOException("请先连接服务器");
        var info = new ProcessStartInfo(SystemSsh.Executable()) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        Process process;
        try { process = Process.Start(info) ?? throw new Win32Exception(); }
        catch (Win32Exception) { throw new SystemSshException(SystemSshFailure.Missing, "未安装 OpenSSH 客户端（设置 › 系统 › 可选功能）"); }
        var run = new ProcessRun(process, input, token, finished => running.TryRemove(finished, out _));
        running[run] = true;
        if (closed) run.Dispose();
        return run;
    }

    public void Dispose()
    {
        closed = true;
        foreach (var run in running.Keys) run.Dispose();
    }

    private sealed class ProcessRun : IRemoteRun, IForward
    {
        private readonly Process process;
        private readonly StringBuilder error = new();
        private readonly CancellationTokenRegistration cancel;
        private int disposed;
        public ProcessRun(Process process, bool input, CancellationToken token, Action<ProcessRun> finished)
        {
            this.process = process;
            process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (error) if (error.Length < 16384) error.AppendLine(e.Data); };
            process.BeginErrorReadLine();
            if (input) Input = process.StandardInput.BaseStream; else process.StandardInput.Close();
            Output = process.StandardOutput.BaseStream;
            cancel = token.Register(Kill);
            Exit = WaitAsync(finished);
        }
        private async Task<int> WaitAsync(Action<ProcessRun> finished)
        {
            try { await process.WaitForExitAsync(); return process.ExitCode; }
            finally { finished(this); }
        }
        public Stream Output { get; }
        public Stream Input { get; } = Stream.Null;
        public Task<int> Exit { get; }
        public string Error { get { lock (error) return error.ToString(); } }
        public bool Alive => !Exit.IsCompleted;
        private void Kill() { try { if (!process.HasExited) process.Kill(true); } catch (Exception e) when (e is InvalidOperationException or Win32Exception) { } }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            cancel.Dispose(); Kill();
            // Release the handles once the exit has been observed.
            _ = Exit.ContinueWith(_ => process.Dispose(), TaskScheduler.Default);
        }
    }
}
