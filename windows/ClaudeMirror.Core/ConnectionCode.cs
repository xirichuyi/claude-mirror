using System.Security.Cryptography;
using System.Text;

namespace ClaudeMirror.Core;

/// <summary>A one-use code from the server panel or <c>install-claude-remote.sh --invite</c>: where to connect, as whom, and with which key.</summary>
public sealed record ConnectionCode(string Name, string Host, int Port, string User, IReadOnlyList<string> HostKeys, string PrivateKey)
{
    public const string Prefix = "cm1.";
    public const string InviteComment = "claude-mirror-invite";
    private static readonly string[] HostKeyTypes = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"];

    public static bool LooksLike(string? text) => text?.Trim().StartsWith(Prefix, StringComparison.Ordinal) == true;

    /// <summary>The fingerprints the SSH connection may see, as OpenSSH prints them.</summary>
    public IReadOnlyList<string> HostKeyFingerprints => HostKeys.Select(key => "SHA256:" + Convert.ToBase64String(SHA256.HashData(Convert.FromBase64String(key.Split(' ')[1]))).TrimEnd('=')).ToList();

    public static ConnectionCode Parse(string text)
    {
        var invalid = new IOException("连接码无效");
        var body = new string(text.Where(c => !char.IsWhiteSpace(c)).ToArray());
        if (!body.StartsWith(Prefix, StringComparison.Ordinal)) throw invalid;
        body = body[Prefix.Length..].Replace('-', '+').Replace('_', '/');
        body += new string('=', (4 - body.Length % 4) % 4);
        string decoded;
        try { decoded = new UTF8Encoding(false, true).GetString(Convert.FromBase64String(body)); } catch (FormatException) { throw invalid; } catch (ArgumentException) { throw invalid; }
        var lines = decoded.Split('\n');
        if (lines[0] != "claude-mirror 1") throw new IOException("连接码版本不支持，请更新 App");
        var fields = new Dictionary<string, string>(); var hostKeys = new List<string>(); var keyLines = new List<string>();
        foreach (var line in lines.Skip(1))
        {
            if (keyLines.Count > 0 || line.StartsWith("-----BEGIN ", StringComparison.Ordinal)) { keyLines.Add(line); continue; }
            var space = line.IndexOf(' ');
            if (space <= 0) continue;
            if (line[..space] == "hostkey") hostKeys.Add(line[(space + 1)..]); else fields[line[..space]] = line[(space + 1)..];
        }
        var privateKey = string.Join("\n", keyLines).Trim() + "\n";
        var host = fields.GetValueOrDefault("host", ""); var user = fields.GetValueOrDefault("user", "");
        var keysValid = hostKeys.Count > 0 && hostKeys.All(key =>
        {
            var parts = key.Split(' ');
            return parts.Length == 2 && HostKeyTypes.Contains(parts[0]) && parts[1].Length >= 60 && parts[1].All(c => char.IsAsciiLetterOrDigit(c) || c is '+' or '/' or '=');
        });
        if (host.Length == 0 || host[0] == '-' || !host.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or ':' or '-' or '_') ||
            user.Length == 0 || user[0] == '-' || !user.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-') ||
            !int.TryParse(fields.GetValueOrDefault("port", "22"), out var port) || port is < 1 or > 65535 || !keysValid ||
            !privateKey.StartsWith("-----BEGIN OPENSSH PRIVATE KEY-----", StringComparison.Ordinal) || !privateKey.Contains("-----END OPENSSH PRIVATE KEY-----"))
            throw invalid;
        return new ConnectionCode(fields.GetValueOrDefault("name", host), host, port, user, hostKeys, privateKey);
    }

    /// <summary>Swaps the invitation key for <paramref name="publicKey"/> in one step, and only while the invitation is still there,
    /// so a code that two people try at once gives access to one of them.</summary>
    public static string ClaimScript(string publicKey) => string.Join("\n",
        "umask 077",
        "F=\"$HOME/.ssh/authorized_keys\"",
        "K=" + Protocol.Quote(publicKey.Trim() + " claude-mirror"),
        "mkdir \"$F.lock\" 2>/dev/null || exit 1",
        "trap 'rmdir \"$F.lock\"' EXIT",
        "grep -q -- ' " + InviteComment + "$' \"$F\" 2>/dev/null || { echo __RCC_USED__; exit 1; }",
        "{ grep -v -- ' " + InviteComment + "$' \"$F\"; [ \"$?\" -le 1 ]; } > \"$F.new\" || exit 1",
        "grep -qxF -- \"$K\" \"$F.new\" || printf '%s\\n' \"$K\" >> \"$F.new\" || exit 1",
        "mv -f \"$F.new\" \"$F\" && chmod 600 \"$F\" || exit 1",
        "echo __RCC_CLAIMED__");
}
