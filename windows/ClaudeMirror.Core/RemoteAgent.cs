using System.Collections.Concurrent;
using System.Text;
using System.Text.Json.Nodes;
using Renci.SshNet;

namespace ClaudeMirror.Core;

public sealed class RemoteAgent : IDisposable
{
    private SshClient? ssh;
    private SshCommand? command;
    private StreamWriter? writer;
    private readonly SemaphoreSlim writeLock = new(1);
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonNode>> requests = new();
    private readonly ConcurrentDictionary<string, Action<JsonObject>> watches = new();
    private readonly CancellationTokenSource lifetime = new();
    private int sequence;
    private bool channelClosed;
    public string Home { get; private set; } = "~";
    public string Digest { get; private set; } = "";
    public event Action<string>? Disconnected;
    public bool Connected => ssh?.IsConnected == true && writer is not null && !lifetime.IsCancellationRequested && !channelClosed;

    public async Task ConnectAsync(HostProfile profile, string password, string keyPassphrase,
        string resourceDirectory, Func<string, Task<bool>> verifyHost)
    {
        if (profile.Port is < 1 or > 65535 || string.IsNullOrWhiteSpace(profile.Host) || string.IsNullOrWhiteSpace(profile.User))
            throw new ArgumentException("请填写主机、用户名和有效端口");
        using var privateKey = string.IsNullOrWhiteSpace(profile.KeyFile) ? null : new PrivateKeyFile(profile.KeyFile, keyPassphrase);
        AuthenticationMethod auth = privateKey is null
            ? new PasswordAuthenticationMethod(profile.User, password)
            : new PrivateKeyAuthenticationMethod(profile.User, privateKey);
        ssh = new SshClient(new ConnectionInfo(profile.Host, profile.Port, profile.User, auth) { Timeout = TimeSpan.FromSeconds(20) });
        ssh.KeepAliveInterval = TimeSpan.FromSeconds(15);
        ssh.HostKeyReceived += (_, e) => e.CanTrust = verifyHost("SHA256:" + Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData(e.HostKey)).TrimEnd('=')).GetAwaiter().GetResult();
        await Task.Run(() => ssh.Connect());
        var manifest = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(resourceDirectory, "manifest.json")))!;
        Digest = manifest["bundleDigest"]!.GetValue<string>();
        var digest = manifest["agentDigest"]!.GetValue<string>();
        var source = await File.ReadAllBytesAsync(Path.Combine(resourceDirectory, "remote-agent.cjs"));
        var remote = "$HOME/.local/share/remotecc/agent/" + digest;
        using (var install = ssh.CreateCommand($"mkdir -p \"{remote}\" && chmod 700 \"{remote}\" && cat > \"{remote}/agent.tmp\" && mv \"{remote}/agent.tmp\" \"{remote}/remote-agent.cjs\""))
        {
            var executing = install.ExecuteAsync(lifetime.Token);
            using (var input = install.CreateInputStream()) { await input.WriteAsync(source); }
            await executing.WaitAsync(TimeSpan.FromSeconds(30));
            if (install.ExitStatus != 0) throw new IOException(install.Error);
        }
        var script = "PATH=\"$PATH:$HOME/.local/bin:$HOME/.volta/bin:/usr/local/bin:/opt/homebrew/bin\"; " +
            "if ! command -v node >/dev/null; then for N in \"$HOME\"/.nvm/versions/node/*/bin/node \"$HOME\"/.local/share/fnm/node-versions/*/installation/bin/node; do [ ! -x \"$N\" ] || PATH=\"$(dirname \"$N\"):$PATH\"; done; fi; export PATH; " +
            $"exec node \"{remote}/remote-agent.cjs\"";
        command = ssh.CreateCommand("bash -lc " + Protocol.Quote(script));
        var execution = command.ExecuteAsync(lifetime.Token);
        writer = new StreamWriter(command.CreateInputStream(), new UTF8Encoding(false)) { AutoFlush = true };
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _ = Task.Run(async () =>
        {
            try
            {
                using var reader = new StreamReader(command.OutputStream);
                while (await reader.ReadLineAsync(lifetime.Token) is { } line)
                {
                    if (!line.StartsWith('{')) continue;
                    var message = JsonNode.Parse(line)!.AsObject();
                    if (message["rcc"]?.GetValue<string>() == "ready") { ready.TrySetResult(); continue; }
                    if (message["sub"] is JsonValue sub)
                    {
                        if (watches.TryGetValue(sub.GetValue<string>(), out var receive) && message["packet"] is JsonObject packet) receive(packet);
                        continue;
                    }
                    if (message["id"] is not JsonValue id || !requests.TryRemove(id.GetValue<int>(), out var pending)) continue;
                    if (message["error"] is not null) pending.TrySetException(new IOException(message["error"]!.GetValue<string>()));
                    else pending.TrySetResult(message["result"]?.DeepClone() ?? new JsonObject());
                }
                await execution;
                throw new IOException("SSH 通道已断开，请重新连接；远端任务会保留");
            }
            catch (Exception e)
            {
                channelClosed = true;
                ready.TrySetException(e);
                foreach (var request in requests.Values) request.TrySetException(e);
                requests.Clear();
                if (!lifetime.IsCancellationRequested) Disconnected?.Invoke(e.Message);
            }
        });
        await ready.Task.WaitAsync(TimeSpan.FromSeconds(30));
        var hello = await CallAsync("file", new { operation = "hello" });
        Home = hello["home"]!.GetValue<string>();
        if (hello["nodeSupported"]?.GetValue<bool>() != true) throw new IOException("远端需要 Node.js 18.14 或更新版本");
        await CallAsync("task", new { operation = "install", digest = Digest, payload = manifest["bundlePayload"]!.GetValue<string>() });
    }
    public async Task<JsonNode> CallAsync(string operation, object parameters)
    {
        var id = Interlocked.Increment(ref sequence);
        var pending = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        requests[id] = pending;
        try
        {
            await WriteAsync(new { id, op = operation, @params = parameters });
            return await pending.Task.WaitAsync(TimeSpan.FromSeconds(60), lifetime.Token);
        }
        finally { requests.TryRemove(id, out _); }
    }
    private async Task WriteAsync(object value)
    {
        await writeLock.WaitAsync(lifetime.Token);
        try { await (writer ?? throw new IOException("未连接")).WriteLineAsync(System.Text.Json.JsonSerializer.Serialize(value)); }
        finally { writeLock.Release(); }
    }
    public async Task WatchAsync(string task, Action<JsonObject> receive)
    {
        foreach (var old in watches.Keys)
        {
            watches.TryRemove(old, out _);
            await WriteAsync(new { cancel = "sub:" + old });
        }
        var subscription = Guid.NewGuid().ToString(); JsonObject? state = null;
        watches[subscription] = packet =>
        {
            if (packet["heartbeat"]?.GetValue<bool>() == true) return;
            state = Protocol.Apply(state, packet); receive((JsonObject)state.DeepClone());
        };
        await CallAsync("taskWatch", new { taskId = task, subscription });
    }
    public async Task<JsonNode> TaskCommandAsync(string task, object value)
    {
        var result = await CallAsync("task", new { operation = "command", taskId = task, commandId = Guid.NewGuid().ToString(), command = value, wait = true });
        if (result["ok"]?.GetValue<bool>() == false)
            throw new IOException(result["error"]?.GetValue<string>() ?? "远端操作失败");
        return result;
    }
    public async Task DownloadAsync(string remotePath, string localPath)
    {
        using var download = ssh!.CreateCommand("cat -- " + Protocol.Quote(remotePath));
        var executing = download.ExecuteAsync(lifetime.Token);
        await using var file = File.Create(localPath);
        await download.OutputStream.CopyToAsync(file, lifetime.Token); await executing;
        if (download.ExitStatus != 0) throw new IOException(download.Error);
    }
    public async Task<string> UploadAsync(string localPath)
    {
        await using var file = File.OpenRead(localPath);
        var hash = Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(file)).ToLowerInvariant(); file.Position = 0;
        var folder = Home + "/.cache/claude-mirror/attachments/" + hash;
        var remote = folder + "/" + Path.GetFileName(localPath);
        using (var existing = ssh!.CreateCommand("test -f " + Protocol.Quote(remote)))
        {
            await existing.ExecuteAsync(lifetime.Token);
            if (existing.ExitStatus == 0) return remote;
        }
        var temporary = remote + "." + Guid.NewGuid().ToString("N") + ".tmp";
        using var upload = ssh!.CreateCommand("mkdir -p " + Protocol.Quote(folder) + " && chmod 700 " + Protocol.Quote(folder) + " && cat > " + Protocol.Quote(temporary) + " && chmod 600 " + Protocol.Quote(temporary) + " && mv " + Protocol.Quote(temporary) + " " + Protocol.Quote(remote));
        var executing = upload.ExecuteAsync(lifetime.Token);
        using (var input = upload.CreateInputStream()) await file.CopyToAsync(input, lifetime.Token);
        await executing;
        if (upload.ExitStatus != 0) throw new IOException(upload.Error);
        return remote;
    }
    public void Dispose()
    {
        lifetime.Cancel(); writer?.Dispose(); command?.Dispose(); ssh?.Dispose();
        foreach (var request in requests.Values) request.TrySetCanceled(); requests.Clear(); watches.Clear();
    }
}
