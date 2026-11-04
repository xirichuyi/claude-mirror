using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace ClaudeMirror.Core;

public sealed record StableUpdate(string Tag, long Length, string Sha256)
{
    public const string Installer = "Claude-Mirror-Setup-x64.exe";
    private const string Repository = "https://github.com/xirichuyi/claude-mirror";
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(8), MaxResponseContentBufferSize = 1024 * 1024 };
    private static readonly Regex TagPattern = new(@"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z");
    private static readonly XDocument Metadata = ReadMetadata();
    public static Version CurrentVersion => Version.Parse(Setting("CFBundleShortVersionString"));
    static StableUpdate() => Client.DefaultRequestHeaders.UserAgent.ParseAdd("Claude-Mirror-Windows/1");

    private static XDocument ReadMetadata()
    {
        using var stream = typeof(StableUpdate).Assembly.GetManifestResourceStream("ReleaseInfo.plist")
            ?? throw new InvalidDataException("缺少版本信息");
        return XDocument.Load(stream);
    }
    private static string Setting(string key) => Metadata.Descendants("key").Single(x => x.Value == key).ElementsAfterSelf().First().Value;

    public static StableUpdate VerifyManifest(string tag, byte[] bytes, byte[] signature, byte[] publicKey)
    {
        var verifier = new Ed25519Signer();
        verifier.Init(false, new Ed25519PublicKeyParameters(publicKey, 0));
        verifier.BlockUpdate(bytes, 0, bytes.Length);
        if (signature.Length != 64 || !verifier.VerifySignature(signature)) throw new InvalidDataException("更新清单签名无效");
        using var doc = JsonDocument.Parse(bytes);
        var root = doc.RootElement;
        var length = root.GetProperty("length").GetInt64();
        var sha = root.GetProperty("sha256").GetString() ?? "";
        if (!TagPattern.IsMatch(tag) || root.GetProperty("tag").GetString() != tag ||
            root.GetProperty("asset").GetString() != Installer || length is <= 0 or > 536870912 ||
            !Regex.IsMatch(sha, @"^[a-fA-F0-9]{64}\z"))
            throw new InvalidDataException("安装包与发布版本不符");
        return new(tag, length, sha);
    }
    public static async Task<StableUpdate?> CheckAsync(CancellationToken token)
    {
        var release = await Client.GetFromJsonAsync<JsonElement>("https://api.github.com/repos/xirichuyi/claude-mirror/releases/latest",token);
        string tag = release.GetProperty("tag_name").GetString() ?? "";
        if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean() || !TagPattern.IsMatch(tag))
            throw new InvalidDataException("最新发布未标记为稳定版");
        if (Version.Parse(tag[1..]) <= CurrentVersion) return null;
        string prefix = $"{Repository}/releases/download/{tag}/windows-update.";
        var bytes = await Client.GetByteArrayAsync(prefix+"json",token);
        var sig = Convert.FromBase64String(await Client.GetStringAsync(prefix+"sig",token));
        return VerifyManifest(tag,bytes,sig,Convert.FromBase64String(Setting("SUPublicEDKey")));
    }
    public async Task VerifyFileAsync(string path, CancellationToken token)
    {
        await using var stream = File.OpenRead(path);
        if (stream.Length != Length || !CryptographicOperations.FixedTimeEquals(await SHA256.HashDataAsync(stream,token), Convert.FromHexString(Sha256)))
            throw new InvalidDataException("安装包未通过 SHA-256 校验");
    }
    public async Task<string> StageAsync(string directory, CancellationToken token)
    {
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory,$"Claude-Mirror-{Tag}-Setup.exe");
        if (File.Exists(path)) {
            try { await VerifyFileAsync(path,token); return path; } catch (InvalidDataException) { }
        }
        string temporary = Path.Combine(directory,Guid.NewGuid()+".part");
        try {
            using var response = await Client.GetAsync($"{Repository}/releases/download/{Tag}/{Installer}",HttpCompletionOption.ResponseHeadersRead,token);
            response.EnsureSuccessStatusCode();
            await using var source = await response.Content.ReadAsStreamAsync(token);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            deadline.CancelAfter(TimeSpan.FromMinutes(8));
            await using (var output = File.Open(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                var buffer = new byte[81920]; int count;
                while ((count = await source.ReadAsync(buffer,deadline.Token)) != 0) {
                    if (output.Length + count > Length) throw new InvalidDataException("安装包长度不符");
                    await output.WriteAsync(buffer.AsMemory(0,count),deadline.Token);
                }
            }
            await VerifyFileAsync(temporary,token);
            File.Move(temporary,path,true);return path;
        } finally { File.Delete(temporary); }
    }
}
