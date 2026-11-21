package claudemirror.app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import claudemirror.core.HostConfig
import claudemirror.core.MirrorJson
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/** What logs in to a server. Kept apart from [HostConfig] so it never ends up in a plain file. */
@Serializable
data class HostSecret(val password: String? = null, val privateKey: String? = null, val passphrase: String? = null)

/**
 * Passwords and private keys, one encrypted file per server. The AES key lives in the
 * Android Keystore and cannot be read out of it, so the files are useless off this device.
 */
class SecretStore(private val directory: File) {
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
        }.generateKey()
    }

    fun read(host: String): HostSecret {
        val bytes = File(directory, host).takeIf { it.exists() }?.readBytes() ?: return HostSecret()
        return runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV))
            MirrorJson.decodeFromString(HostSecret.serializer(), cipher.doFinal(bytes, IV, bytes.size - IV).decodeToString())
        }.getOrDefault(HostSecret())
    }

    fun write(host: String, secret: HostSecret) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        directory.mkdirs()
        File(directory, host).writeBytes(cipher.iv + cipher.doFinal(MirrorJson.encodeToString(HostSecret.serializer(), secret).toByteArray()))
    }

    fun delete(host: String) {
        File(directory, host).delete()
    }

    private companion object {
        const val ALIAS = "claude-mirror-secrets"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV = 12
    }
}

class HostStore(private val file: File) {
    private val serializer = ListSerializer(HostConfig.serializer())

    fun load(): List<HostConfig> =
        runCatching { MirrorJson.decodeFromString(serializer, file.readText()) }.getOrDefault(emptyList())

    fun save(hosts: List<HostConfig>) {
        val temporary = File(file.path + ".tmp")
        temporary.writeText(MirrorJson.encodeToString(serializer, hosts))
        temporary.renameTo(file)
    }
}
