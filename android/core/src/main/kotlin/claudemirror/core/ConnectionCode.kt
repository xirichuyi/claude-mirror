package claudemirror.core

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.util.OpenSSHPrivateKeyUtil
import org.bouncycastle.crypto.util.OpenSSHPublicKeyUtil

/** A one-use code from the server panel or `install-claude-remote.sh --invite`: where to connect, as whom, and with which key. */
data class ConnectionCode(
    val name: String,
    val host: String,
    val port: Int,
    val user: String,
    val hostKeys: List<String>,
    val privateKey: String,
) {
    /** What [fingerprint] prints for the first pinned key; the connection only accepts that key. */
    val hostKeyFingerprint: String get() {
        val blob = Base64.getDecoder().decode(hostKeys.first().split(' ')[1])
        return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(blob))
    }

    companion object {
        const val PREFIX = "cm1."
        const val INVITE_COMMENT = "claude-mirror-invite"
        private val HOST_KEY_TYPES = setOf("ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521")

        fun looksLike(text: String) = text.trim().startsWith(PREFIX)

        fun parse(text: String): ConnectionCode {
            val invalid = RemoteException("连接码无效")
            val body = text.filterNot(Char::isWhitespace)
            if (!body.startsWith(PREFIX)) throw invalid
            val decoded = runCatching { Base64.getUrlDecoder().decode(body.removePrefix(PREFIX)).decodeToString() }.getOrElse { throw invalid }
            val lines = decoded.split('\n')
            if (lines.first() != "claude-mirror 1") throw RemoteException("连接码版本不支持，请更新 App")
            val fields = HashMap<String, String>()
            val hostKeys = ArrayList<String>()
            val keyLines = ArrayList<String>()
            for (line in lines.drop(1)) {
                if (keyLines.isNotEmpty() || line.startsWith("-----BEGIN ")) { keyLines += line; continue }
                val field = line.substringBefore(' ', ""); val value = line.substringAfter(' ', "")
                if (field == "hostkey") hostKeys += value else if (field.isNotEmpty()) fields[field] = value
            }
            val privateKey = keyLines.joinToString("\n").trim() + "\n"
            val host = fields["host"].orEmpty()
            val user = fields["user"].orEmpty()
            val port = (fields["port"] ?: "22").toIntOrNull()
            val keysValid = hostKeys.isNotEmpty() && hostKeys.all { key ->
                val parts = key.split(' ')
                parts.size == 2 && parts[0] in HOST_KEY_TYPES && parts[1].length >= 60 && parts[1].all { it.isLetterOrDigit() && it.code < 128 || it in "+/=" }
            }
            if (host.isEmpty() || host.startsWith("-") || !host.all { it.isLetterOrDigit() || it in ".:-_" } ||
                user.isEmpty() || user.startsWith("-") || !user.all { it.isLetterOrDigit() || it in "._-" } ||
                port == null || port !in 1..65535 || !keysValid ||
                !privateKey.startsWith("-----BEGIN OPENSSH PRIVATE KEY-----") || "-----END OPENSSH PRIVATE KEY-----" !in privateKey
            ) throw invalid
            return ConnectionCode(fields["name"] ?: host, host, port, user, hostKeys, privateKey)
        }

        /** Adds [publicKey] to the account's authorized_keys once, keeping every other line. */
        fun authorizeScript(publicKey: String): String = listOf(
            "umask 077",
            "F=\"\$HOME/.ssh/authorized_keys\"",
            "mkdir -p \"\$HOME/.ssh\" && chmod 700 \"\$HOME/.ssh\" && touch \"\$F\" && chmod 600 \"\$F\" || exit 1",
            "K=" + shellQuote("$publicKey claude-mirror"),
            "if [ -s \"\$F\" ] && [ -n \"\$(tail -c 1 \"\$F\")\" ]; then echo >> \"\$F\"; fi",
            "grep -qxF \"\$K\" \"\$F\" || printf '%s\\n' \"\$K\" >> \"\$F\" || exit 1",
            "echo __RCC_KEY_OK__",
        ).joinToString("\n")

        /** Run after the app's own key is known to work: the invitation key stops working. */
        val DROP_INVITE = listOf(
            "F=\"\$HOME/.ssh/authorized_keys\"",
            "[ -f \"\$F\" ] || exit 1",
            "umask 077",
            "{ grep -v -- ' $INVITE_COMMENT\$' \"\$F\"; [ \"\$?\" -le 1 ]; } > \"\$F.new\" && mv -f \"\$F.new\" \"\$F\" && chmod 600 \"\$F\" || exit 1",
            "echo __RCC_CLAIMED__",
        ).joinToString("\n")
    }
}

/** A new Ed25519 key: the OpenSSH private key file and its `ssh-ed25519 <base64>` public half. */
class LoginKey(val privateKey: String, val publicKey: String) {
    companion object {
        fun generate(): LoginKey {
            val generator = Ed25519KeyPairGenerator().apply { init(Ed25519KeyGenerationParameters(SecureRandom())) }
            val pair = generator.generateKeyPair()
            val private = Base64.getMimeEncoder(70, "\n".toByteArray()).encodeToString(OpenSSHPrivateKeyUtil.encodePrivateKey(pair.private))
            val public = Base64.getEncoder().encodeToString(OpenSSHPublicKeyUtil.encodePublicKey(pair.public as Ed25519PublicKeyParameters))
            return LoginKey("-----BEGIN OPENSSH PRIVATE KEY-----\n$private\n-----END OPENSSH PRIVATE KEY-----\n", "ssh-ed25519 $public")
        }
    }
}
