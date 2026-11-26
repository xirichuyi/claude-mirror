using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Text;
using System.Text.Json.Nodes;
using Renci.SshNet;

namespace ClaudeMirror.Core;

public sealed class RemoteAgent : IDisposable
{
    private ISshLink? ssh;
    private readonly Dictionary<int, (Tunnel Tunnel, IForward Port)> forwards = [];
    private IRemoteRun? command;
    private StreamWriter? writer;
    private readonly SemaphoreSlim writeLock = new(1);
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonNode>> requests = new();
    private readonly ConcurrentDictionary<string, Action<JsonObject>> watches = new();
    private readonly ConcurrentDictionary<string, string> watching = new();
    private readonly CancellationTokenSource lifetime = new();
    private int sequence;
    private bool channelClosed, attached;
    // After the `frames` upgrade the channel carries binary frames (docs/agent-wire.md).
    private volatile bool framed;
    private int upgradeId = -1;
    private readonly ConcurrentDictionary<int, Func<byte[]?, string?, Task>> reads = new();
    private readonly ConcurrentDictionary<int, Upload> uploads = new();
    private sealed class Upload
    {
        public readonly TaskCompletionSource<long> Offset = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private long credit;
        private TaskCompletionSource signal = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void Grant(long bytes) { TaskCompletionSource old; lock (this) { credit += bytes; old = signal; signal = new(TaskCreationOptions.RunContinuationsAsynchronously); } old.TrySetResult(); }
        public void Spend(long bytes) { lock (this) credit -= bytes; }
        public (long Credit, Task Changed) State() { lock (this) return (credit, signal.Task); }
    }
    public string Home { get; private set; } = "~";
    public string Digest { get; private set; } = "";
    /// <summary>The agent's hello reply: claude path, persistence warning, Node version.</summary>
    public JsonNode? Hello { get; private set; }
    public HostProfile? Profile { get; private set; }
    /// <summary>SSH is up even when the agent could not start (for example Node.js is missing).</summary>
    public bool SshConnected => (attached || ssh?.Connected == true) && !lifetime.IsCancellationRequested;
    public event Action<string>? Disconnected;
    public bool Connected => (attached || ssh?.Connected == true) && writer is not null && !lifetime.IsCancellationRequested && !channelClosed;

    public async Task ConnectAsync(HostProfile profile, string password, string keyPassphrase,
        string resourceDirectory, Func<string, Task<bool>> verifyHost)
    {
        if (profile.SystemSsh) { await ConnectSystemAsync(profile, resourceDirectory); return; }
        if (profile.Port is < 1 or > 65535 || string.IsNullOrWhiteSpace(profile.Host) || string.IsNullOrWhiteSpace(profile.User))
            throw new ArgumentException("请填写主机、用户名和有效端口");
        using var privateKey = string.IsNullOrWhiteSpace(profile.KeyFile) ? null : new PrivateKeyFile(profile.KeyFile, keyPassphrase);
        AuthenticationMethod auth = privateKey is null
            ? new PasswordAuthenticationMethod(profile.User, password)
            : new PrivateKeyAuthenticationMethod(profile.User, privateKey);
        static string Fingerprint(byte[] key) => "SHA256:" + Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData(key)).TrimEnd('=');
        var client = new SshClient(new ConnectionInfo(profile.Host, profile.Port, profile.User, auth) { Timeout = TimeSpan.FromSeconds(20) });
        ssh = new LibraryLink(client);
        client.KeepAliveInterval = TimeSpan.FromSeconds(15);
        client.HostKeyReceived += (_, e) => e.CanTrust = verifyHost(Fingerprint(e.HostKey)).GetAwaiter().GetResult();
        await Task.Run(() => client.Connect());
        Profile = profile;
        await StartAgentAsync(resourceDirectory);
    }

    /// <summary>Connects with the computer's OpenSSH client. Every command is its own <c>ssh</c> process; nothing listens on this computer.</summary>
    /// <param name="config">An SSH config file to use instead of the user's (tests).</param>
    public async Task ConnectSystemAsync(HostProfile profile, string resourceDirectory, string? config = null)
    {
        SystemSsh.Validate(profile);
        var link = new SystemSshLink(profile, config); ssh = link;
        using (var probe = link.Run("echo __RCC_OK__", false, lifetime.Token))
        {
            using var reader = new StreamReader(probe.Output);
            var reading = reader.ReadToEndAsync(lifetime.Token);
            int status;
            try { status = await probe.Exit.WaitAsync(TimeSpan.FromSeconds(90)); }
            catch (TimeoutException) { throw new SystemSshException(SystemSshFailure.Other, "系统 SSH 连接超时"); }
            if (status != 0 || !(await reading).Contains("__RCC_OK__")) throw SystemSsh.Explain(probe.Error);
        }
        Profile = profile;
        await StartAgentAsync(resourceDirectory);
    }

    /// <summary>Starts the remote agent over the existing SSH connection. Safe to call again after one-click setup.</summary>
    public async Task StartAgentAsync(string resourceDirectory)
    {
        if (ssh is null || !ssh.Connected) throw new IOException("请先连接服务器");
        command?.Dispose(); writer = null; channelClosed = false; Hello = null; framed = false;
        var manifest = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(resourceDirectory, "manifest.json")))!;
        Digest = manifest["bundleDigest"]!.GetValue<string>();
        var digest = manifest["agentDigest"]!.GetValue<string>();
        var source = await File.ReadAllBytesAsync(Path.Combine(resourceDirectory, "remote-agent.cjs"));
        var remote = "$HOME/.local/share/remotecc/agent/" + digest;
        using (var install = ssh.Run($"mkdir -p \"{remote}\" && chmod 700 \"{remote}\" && cat > \"{remote}/agent.tmp\" && mv \"{remote}/agent.tmp\" \"{remote}/remote-agent.cjs\"", true, lifetime.Token))
        {
            using (var input = install.Input) { await input.WriteAsync(source); }
            if (await install.Exit.WaitAsync(TimeSpan.FromSeconds(60)) != 0) throw new IOException(install.Error);
        }
        // Prefer the Node.js that one-click setup installs; report a missing or old Node instead of failing obscurely.
        var script = "PATH=\"$PATH:$HOME/.local/bin:$HOME/.volta/bin:/usr/local/bin:/opt/homebrew/bin\"; " +
            "M=\"$HOME/.local/share/claude-mirror/node/bin\"; if [ -x \"$M/node\" ]; then PATH=\"$M:$PATH\"; " +
            "elif ! command -v node >/dev/null; then for N in \"$HOME\"/.nvm/versions/node/*/bin/node \"$HOME\"/.local/share/fnm/node-versions/*/installation/bin/node; do [ ! -x \"$N\" ] || PATH=\"$(dirname \"$N\"):$PATH\"; done; fi; export PATH; " +
            "command -v node >/dev/null 2>&1 || { echo __RCC_NO_NODE__; exit 0; }; " +
            "V=\"$(node --version 2>/dev/null)\"; V=\"${V#v}\"; J=\"${V%%.*}\"; R=\"${V#*.}\"; R=\"${R%%.*}\"; " +
            "case \"$J$R\" in *[!0-9]*|\"\") ;; *) if [ \"$J\" -lt 18 ] || { [ \"$J\" -eq 18 ] && [ \"$R\" -lt 14 ]; }; then echo \"__RCC_OLD_NODE__ v$V\"; exit 0; fi ;; esac; " +
            $"exec node \"{remote}/remote-agent.cjs\"";
        command = ssh.Run("bash -lc " + Protocol.Quote(script), true, lifetime.Token);
        writer = new StreamWriter(command.Input, new UTF8Encoding(false)) { AutoFlush = true };
        var channel = command!;
        var ready = Listen(channel.Output, channel.Exit, () => channel == command);
        await ready.WaitAsync(TimeSpan.FromSeconds(30));
        upgradeId = Interlocked.Increment(ref sequence);
        await CallAsync(upgradeId, "frames", new { version = 1 }, TimeSpan.FromSeconds(60));
        var hello = await CallAsync("file", new { operation = "hello" });
        Home = hello["home"]!.GetValue<string>();
        if (hello["nodeSupported"]?.GetValue<bool>() != true) { channelClosed = true; throw new RemoteSetupException(true, hello["node"]?.GetValue<string>()); }
        Hello = hello;
        await CallAsync("task", new { operation = "install", digest = Digest, payload = manifest["bundlePayload"]!.GetValue<string>() });
    }
    /// <summary>Reads the agent's JSON lines until the stream ends. The returned task completes at the agent's ready line.</summary>
    private Task Listen(Stream output, Task finished, Func<bool> current)
    {
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        RemoteSetupException? setupFailure = null;
        _ = Task.Run(async () =>
        {
            try
            {
                var chunk = new byte[256 * 1024];
                var buffer = new byte[1024 * 1024];
                int length = 0, read;
                while ((read = await output.ReadAsync(chunk, lifetime.Token)) > 0)
                {
                    if (length + read > buffer.Length) Array.Resize(ref buffer, Math.Max(buffer.Length * 2, length + read));
                    Buffer.BlockCopy(chunk, 0, buffer, length, read); length += read;
                    var position = 0;
                    while (true)
                    {
                        if (!framed)
                        {
                            var newline = Array.IndexOf(buffer, (byte)10, position, length - position);
                            if (newline < 0) break;
                            var line = Encoding.UTF8.GetString(buffer, position, newline - position).TrimEnd('\r');
                            position = newline + 1;
                            if (line == "__RCC_NO_NODE__") { setupFailure = new RemoteSetupException(false); ready.TrySetException(setupFailure); continue; }
                            if (line.StartsWith("__RCC_OLD_NODE__ ")) { setupFailure = new RemoteSetupException(true, line["__RCC_OLD_NODE__ ".Length..]); ready.TrySetException(setupFailure); continue; }
                            if (!line.StartsWith('{')) continue;
                            var message = JsonNode.Parse(line)!.AsObject();
                            if (message["rcc"]?.GetValue<string>() == "ready") { ready.TrySetResult(); continue; }
                            Dispatch(message);
                        }
                        else
                        {
                            if (length - position < 4) break;
                            var size = BinaryPrimitives.ReadInt32BigEndian(buffer.AsSpan(position));
                            if (size < 5 || size > 64 * 1024 * 1024) throw new IOException("远端代理数据损坏");
                            if (length - position < 4 + size) break;
                            var type = buffer[position + 4];
                            var id = BinaryPrimitives.ReadInt32BigEndian(buffer.AsSpan(position + 5));
                            var payload = buffer.AsSpan(position + 9, size - 5).ToArray();
                            position += 4 + size;
                            await ReceiveFrame(type, id, payload);
                        }
                    }
                    Buffer.BlockCopy(buffer, position, buffer, 0, length - position); length -= position;
                }
                await finished;
                throw new IOException("SSH 通道已断开，请重新连接；远端任务会保留");
            }
            catch (Exception e)
            {
                channelClosed = true;
                ready.TrySetException(e);
                foreach (var request in requests.Values) request.TrySetException(e);
                requests.Clear();
                foreach (var stream in reads.Values) _ = stream(null, e.Message);
                foreach (var upload in uploads.Values) { upload.Offset.TrySetException(e); upload.Grant(0); }
                // A missing Node.js is reported by ConnectAsync as a setup step, not as a lost connection.
                if (!lifetime.IsCancellationRequested && setupFailure is null && current()) Disconnected?.Invoke(e.Message);
            }
        });
        return ready.Task;
    }

    private void Dispatch(JsonObject message)
    {
        if (message["sub"] is JsonValue sub)
        {
            if (watches.TryGetValue(sub.GetValue<string>(), out var receive) && message["packet"] is JsonObject packet) receive(packet);
            return;
        }
        if (message["stream"] is JsonValue stream)
        {
            if (uploads.TryGetValue(stream.GetValue<int>(), out var upload)) upload.Offset.TrySetResult(message["offset"]?.GetValue<long>() ?? 0);
            return;
        }
        if (message["id"] is not JsonValue value) return;
        var id = value.GetValue<int>();
        // Switch before anyone waiting on the reply writes again.
        if (id == upgradeId && message["result"]?["version"]?.GetValue<int>() == 1) framed = true;
        if (!requests.TryRemove(id, out var pending)) return;
        if (message["error"] is not null) pending.TrySetException(new IOException(message["error"]!.GetValue<string>()));
        else pending.TrySetResult(message["result"]?.DeepClone() ?? new JsonObject());
    }

    private async Task ReceiveFrame(byte type, int id, byte[] payload)
    {
        switch (type)
        {
            case 1: Dispatch(JsonNode.Parse(payload)!.AsObject()); break;
            case 2 when payload.Length >= 4:
                var size = BinaryPrimitives.ReadInt32BigEndian(payload);
                var message = JsonNode.Parse(payload.AsSpan(4, size))!.AsObject();
                if (message["result"] is JsonObject result) result["inlineData"] = Convert.ToBase64String(payload, 4 + size, payload.Length - 4 - size);
                Dispatch(message); break;
            case 3: if (reads.TryGetValue(id, out var stream)) await stream(payload, null); break;
            case 4: if (reads.TryRemove(id, out var ended)) await ended(null, payload.Length == 0 ? null : Encoding.UTF8.GetString(payload)); break;
            case 5 when payload.Length >= 4: if (uploads.TryGetValue(id, out var upload)) upload.Grant(BinaryPrimitives.ReadUInt32BigEndian(payload)); break;
        }
    }

    private static byte[] Frame(byte type, int id, ReadOnlySpan<byte> payload)
    {
        var frame = new byte[9 + payload.Length];
        BinaryPrimitives.WriteInt32BigEndian(frame, 5 + payload.Length); frame[4] = type;
        BinaryPrimitives.WriteInt32BigEndian(frame.AsSpan(5), id); payload.CopyTo(frame.AsSpan(9));
        return frame;
    }

    private async Task WriteFrameAsync(byte type, int id, ReadOnlyMemory<byte> payload)
    {
        await writeLock.WaitAsync(lifetime.Token);
        try
        {
            var stream = (writer ?? throw new IOException("未连接")).BaseStream;
            await stream.WriteAsync(Frame(type, id, payload.Span), lifetime.Token); await stream.FlushAsync(lifetime.Token);
        }
        finally { writeLock.Release(); }
    }

    private static byte[] Credit(int bytes) { var value = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(value, bytes); return value; }

    /// <summary>Speaks the agent protocol over two streams instead of SSH: the built-in demo, or a local agent in tests.</summary>
    public static async Task<RemoteAgent> AttachAsync(Stream toAgent, Stream fromAgent, HostProfile profile)
    {
        var agent = new RemoteAgent { attached = true, Profile = profile, Digest = new string('0', 64) };
        agent.writer = new StreamWriter(toAgent, new UTF8Encoding(false)) { AutoFlush = true };
        await agent.Listen(fromAgent, Task.CompletedTask, () => true).WaitAsync(TimeSpan.FromSeconds(30));
        var hello = await agent.CallAsync("file", new { operation = "hello" });
        agent.Home = hello["home"]!.GetValue<string>(); agent.Hello = hello;
        return agent;
    }
    /// <summary>Proves a key logs in on its own, pinning the host fingerprint already trusted for this host.</summary>
    public static async Task VerifyKeyLoginAsync(HostProfile profile, string expectedFingerprint)
    {
        using var key = new PrivateKeyFile(profile.KeyFile!);
        using var probe = new SshClient(new ConnectionInfo(profile.Host, profile.Port, profile.User, new PrivateKeyAuthenticationMethod(profile.User, key)) { Timeout = TimeSpan.FromSeconds(20) });
        probe.HostKeyReceived += (_, e) => e.CanTrust = "SHA256:" + Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData(e.HostKey)).TrimEnd('=') == expectedFingerprint;
        await Task.Run(() => { probe.Connect(); probe.Disconnect(); });
    }

    /// <summary>Whether Claude Code is installed and logged in on the server.</summary>
    public Task<JsonNode> ClaudeStatusAsync() => CallAsync("file", new { operation = "claudeStatus" });

    /// <summary>Runs the bundled install-claude-remote.sh over SSH, streaming merged output lines. Returns its exit status.</summary>
    public async Task<int> InstallAsync(string resourceDirectory, Action<string> output, CancellationToken token)
    {
        if (ssh is null || !ssh.Connected) throw new IOException("请先连接服务器");
        var installer = await File.ReadAllBytesAsync(Path.Combine(resourceDirectory, "install-claude-remote.sh"), token);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, lifetime.Token);
        using var run = ssh.Run(RemoteInstaller.Command, true, linked.Token);
        using (var input = run.Input) await input.WriteAsync(installer, token);
        using (var reader = new StreamReader(run.Output))
            while (await reader.ReadLineAsync(linked.Token) is { } line) output(line);
        return await run.Exit;
    }

    /// <summary>Runs a short script over SSH and returns its standard output.</summary>
    public async Task<string> RunScriptAsync(string script)
    {
        if (ssh is null || !ssh.Connected) throw new IOException("请先连接服务器");
        using var run = ssh.Run("sh -c " + Protocol.Quote(script), false, lifetime.Token);
        using var reader = new StreamReader(run.Output);
        var reading = reader.ReadToEndAsync(lifetime.Token);
        if (await run.Exit.WaitAsync(TimeSpan.FromSeconds(60)) != 0) throw new IOException(string.IsNullOrWhiteSpace(run.Error) ? "远端命令失败" : run.Error);
        return await reading;
    }

    public Task<JsonNode> CallAsync(string operation, object parameters) =>
        CallAsync(Interlocked.Increment(ref sequence), operation, parameters, TimeSpan.FromSeconds(60));

    private async Task<JsonNode> CallAsync(int id, string operation, object parameters, TimeSpan timeout)
    {
        var pending = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        requests[id] = pending;
        try
        {
            await WriteAsync(new { id, op = operation, @params = parameters });
            return await pending.Task.WaitAsync(timeout, lifetime.Token);
        }
        finally { requests.TryRemove(id, out _); }
    }
    private async Task WriteAsync(object value)
    {
        await writeLock.WaitAsync(lifetime.Token);
        try
        {
            var current = writer ?? throw new IOException("未连接");
            if (!framed) await current.WriteLineAsync(System.Text.Json.JsonSerializer.Serialize(value));
            else
            {
                await current.BaseStream.WriteAsync(Frame(1, 0, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(value)), lifetime.Token);
                await current.BaseStream.FlushAsync(lifetime.Token);
            }
        }
        finally { writeLock.Release(); }
    }
    /// <summary>Follows a remote task. Several tasks can be followed at once; watching a task again replaces its earlier watch.</summary>
    public async Task WatchAsync(string task, Action<JsonObject> receive)
    {
        var subscription = Guid.NewGuid().ToString(); JsonObject? state = null;
        watches[subscription] = packet =>
        {
            if (packet["heartbeat"]?.GetValue<bool>() == true) return;
            state = Protocol.Apply(state, packet); receive((JsonObject)state.DeepClone());
        };
        string? earlier = null;
        watching.AddOrUpdate(task, subscription, (_, old) => { earlier = old; return subscription; });
        if (earlier is not null) await CancelWatchAsync(earlier);
        try { await CallAsync("taskWatch", new { taskId = task, subscription }); }
        catch
        {
            watches.TryRemove(subscription, out _);
            watching.TryRemove(new KeyValuePair<string, string>(task, subscription));
            throw;
        }
    }
    /// <summary>Stops following a task; the task itself keeps running on the server.</summary>
    public async Task UnwatchAsync(string task)
    {
        if (watching.TryRemove(task, out var subscription)) await CancelWatchAsync(subscription);
    }
    private async Task CancelWatchAsync(string subscription)
    {
        watches.TryRemove(subscription, out _);
        await WriteAsync(new { cancel = "sub:" + subscription });
    }
    public IReadOnlyCollection<string> Watched => watching.Keys.ToList();
    public async Task<JsonNode> TaskCommandAsync(string task, object value)
    {
        var result = await CallAsync("task", new { operation = "command", taskId = task, commandId = Guid.NewGuid().ToString(), command = value, wait = true });
        if (result["ok"]?.GetValue<bool>() == false)
            throw new IOException(result["error"]?.GetValue<string>() ?? "远端操作失败");
        return result;
    }
    public async Task DownloadAsync(string remotePath, string localPath)
    {
        if (framed) { await ReadAsync(remotePath, localPath); return; }
        using var download = ssh!.Run("cat -- " + Protocol.Quote(remotePath), false, lifetime.Token);
        await using var file = File.Create(localPath);
        await download.Output.CopyToAsync(file, lifetime.Token);
        if (await download.Exit != 0) throw new IOException(download.Error);
    }
    /// <summary>Streams a file over the agent channel; the agent sends no more than the credit granted back as bytes are written.</summary>
    private async Task ReadAsync(string remotePath, string localPath)
    {
        var id = Interlocked.Increment(ref sequence);
        await using var file = File.Create(localPath);
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        reads[id] = async (data, error) =>
        {
            if (data is not null)
            {
                try { await file.WriteAsync(data, lifetime.Token); await WriteFrameAsync(5, id, Credit(data.Length)); }
                catch (Exception e) { reads.TryRemove(id, out _); done.TrySetException(e); }
            }
            else if (error is null) done.TrySetResult();
            else done.TrySetException(new IOException(error));
        };
        try
        {
            var reply = await CallAsync(id, "file", new { operation = "read", path = remotePath, window = 2 * 1024 * 1024 }, TimeSpan.FromSeconds(60));
            await done.Task.WaitAsync(lifetime.Token);
            if (file.Length != reply["size"]!.GetValue<long>()) throw new IOException("下载未完成，可重试");
        }
        catch
        {
            if (reads.TryRemove(id, out _)) await WriteAsync(new { cancel = id });
            throw;
        }
    }

    /// <summary>Sends an attachment over the agent channel. The agent keeps a broken upload and asks for the rest next time.</summary>
    private async Task<string> WriteAsync(FileStream file, string hash, string name)
    {
        var lookup = await CallAsync("file", new { operation = "attachmentLookup", name, digest = hash });
        if (lookup["file"] is JsonObject stored) return stored["path"]!.GetValue<string>();
        var id = Interlocked.Increment(ref sequence);
        var upload = new Upload();
        uploads[id] = upload;
        try
        {
            var reply = CallAsync(id, "file", new { operation = "write", attachment = true, digest = hash, name, size = file.Length }, TimeSpan.FromHours(24));
            if (await Task.WhenAny(upload.Offset.Task, reply) == reply) await reply;
            file.Position = await upload.Offset.Task;
            var chunk = new byte[256 * 1024];
            while (true)
            {
                var (credit, changed) = upload.State();
                if (credit <= 0)
                {
                    if (await Task.WhenAny(changed, reply) == reply) { await reply; throw new IOException("上传未完成"); }
                    continue;
                }
                var count = await file.ReadAsync(chunk.AsMemory(0, (int)Math.Min(credit, chunk.Length)), lifetime.Token);
                if (count == 0) break;
                upload.Spend(count);
                await WriteFrameAsync(3, id, chunk.AsMemory(0, count));
            }
            await WriteFrameAsync(4, id, ReadOnlyMemory<byte>.Empty);
            return (await reply)["path"]!.GetValue<string>();
        }
        finally { uploads.TryRemove(id, out _); }
    }

    /// <summary>
    /// Stores an attachment where the account Claude runs as can read it. A root login writes it as that account, into that account's home:
    /// root's own folders are closed to it, and writing as root into a folder the account controls would follow any link left there.
    /// The command reads the file on stdin and prints the path it was stored at. The modes are set outright: a default ACL on the home overrides umask.
    /// </summary>
    public static string UploadForAccountCommand(string account, string hash, string name)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(account, "^[a-z_][a-z0-9_-]{0,31}$")) throw new ArgumentException("无效的 Claude 执行账号");
        var temporary = name + "." + Guid.NewGuid().ToString("N") + ".tmp";
        return $"if [ \"$(id -u)\" = 0 ]; then home=$(getent passwd {account} | cut -d: -f6); run=\"$(command -v runuser || echo /usr/sbin/runuser) -u {account} --\"; else home=$HOME; run=; fi; "
            + "test -n \"$home\" && $run sh -c 'umask 077; mkdir -p \"$1\" && chmod 700 \"$1\" && : > \"$1/$3\" && chmod 600 \"$1/$3\" && cat >> \"$1/$3\" && mv \"$1/$3\" \"$1/$2\" && printf %s \"$1/$2\"' sh "
            + $"\"$home/.cache/claude-mirror/attachments/{hash}\" {Protocol.Quote(name)} {Protocol.Quote(temporary)}";
    }
    /// <param name="account">The execution account of the conversation the file is for; empty when Claude runs as the SSH user.</param>
    public async Task<string> UploadAsync(string localPath, string account = "")
    {
        await using var file = File.OpenRead(localPath);
        var hash = Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(file)).ToLowerInvariant(); file.Position = 0;
        if (account.Length > 0)
        {
            using var stored = ssh!.Run(UploadForAccountCommand(account, hash, Path.GetFileName(localPath)), true, lifetime.Token);
            using var reader = new StreamReader(stored.Output); var path = reader.ReadToEndAsync(lifetime.Token);
            using (var input = stored.Input) await file.CopyToAsync(input, lifetime.Token);
            if (await stored.Exit != 0 || (await path).Length == 0) throw new IOException(stored.Error.Trim().Length > 0 ? stored.Error.Trim() : $"无法把附件交给执行账号 {account}");
            return await path;
        }
        if (framed) return await WriteAsync(file, hash, Path.GetFileName(localPath));
        var folder = Home + "/.cache/claude-mirror/attachments/" + hash;
        var remote = folder + "/" + Path.GetFileName(localPath);
        using (var existing = ssh!.Run("test -f " + Protocol.Quote(remote), false, lifetime.Token))
        {
            if (await existing.Exit == 0) return remote;
        }
        var temporary = remote + "." + Guid.NewGuid().ToString("N") + ".tmp";
        using var upload = ssh!.Run("mkdir -p " + Protocol.Quote(folder) + " && chmod 700 " + Protocol.Quote(folder) + " && cat > " + Protocol.Quote(temporary) + " && chmod 600 " + Protocol.Quote(temporary) + " && mv " + Protocol.Quote(temporary) + " " + Protocol.Quote(remote), true, lifetime.Token);
        using (var input = upload.Input) await file.CopyToAsync(input, lifetime.Token);
        if (await upload.Exit != 0) throw new IOException(upload.Error);
        return remote;
    }
    /// <summary>Makes a port on the server's loopback reachable at 127.0.0.1 on this computer for as long as the connection lasts.</summary>
    public async Task ForwardAsync(Tunnel tunnel)
    {
        if (tunnel.LocalPort is < 1 or > 65535 || tunnel.RemotePort is < 1 or > 65535) throw new ArgumentException("端口需在 1–65535 之间");
        if (ssh is not { Connected: true } link) throw new IOException("请先连接服务器");
        lock (forwards)
        {
            if (forwards.TryGetValue(tunnel.LocalPort, out var known) && known.Port.Alive) throw new IOException($"本地端口 {tunnel.LocalPort} 已在转发");
            // Reserve the port so a second request cannot start the same forward while this one is opening.
            forwards[tunnel.LocalPort] = (tunnel, Opening.Instance);
        }
        try
        {
            var port = await Task.Run(() => link.Forward(tunnel));
            lock (forwards)
            {
                if (!lifetime.IsCancellationRequested) { forwards[tunnel.LocalPort] = (tunnel, port); return; }
            }
            port.Dispose(); throw new IOException("连接已关闭");
        }
        catch { lock (forwards) if (forwards.TryGetValue(tunnel.LocalPort, out var entry) && entry.Port == Opening.Instance) forwards.Remove(tunnel.LocalPort); throw; }
    }
    private sealed class Opening : IForward { public static readonly Opening Instance = new(); public bool Alive => true; public void Dispose() { } }

    public void CloseForward(int localPort)
    {
        lock (forwards)
        {
            if (!forwards.Remove(localPort, out var entry)) return;
            entry.Port.Dispose();
        }
    }

    /// <summary>The forwards asked for on this connection. After a lost connection they are what a reconnect restores.</summary>
    public IReadOnlyList<Tunnel> Tunnels { get { lock (forwards) return forwards.Values.Select(entry => entry.Tunnel).OrderBy(tunnel => tunnel.LocalPort).ToList(); } }

    public void Dispose()
    {
        lifetime.Cancel();
        lock (forwards) { foreach (var entry in forwards.Values) entry.Port.Dispose(); forwards.Clear(); } writer?.Dispose(); command?.Dispose(); ssh?.Dispose();
        foreach (var request in requests.Values) request.TrySetCanceled(); requests.Clear(); watches.Clear();
    }
}
