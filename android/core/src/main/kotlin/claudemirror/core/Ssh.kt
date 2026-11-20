package claudemirror.core

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import net.schmizz.keepalive.KeepAliveProvider
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.userauth.UserAuthException
import net.schmizz.sshj.userauth.password.PasswordUtils

class SshSecret(val password: String? = null, val privateKey: String? = null, val passphrase: String? = null)

/** The server is new to this device; the user has to accept [fingerprint] once. */
class UnknownHostKeyException(val fingerprint: String) : Exception("首次连接这台服务器，需要确认它的密钥指纹")

/** The server presents a different key than the one accepted earlier. Never accepted silently. */
class HostKeyChangedException(val fingerprint: String) : Exception("服务器的密钥与上次连接时不同，连接已中止。如果服务器重装过，请在服务器设置里重新确认指纹。")

/** The fingerprint as OpenSSH prints it: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. */
fun fingerprint(key: PublicKey): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(Buffer.PlainBuffer().putPublicKey(key).compactData)
    return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest)
}

/** Runs commands over one SSH connection per server. */
class SshLauncher(private val secret: (HostConfig) -> SshSecret) : Launcher {
    private val clients = HashMap<String, SSHClient>()

    override fun start(host: HostConfig, command: String): RemoteProcess {
        val client = synchronized(clients) {
            clients[host.id]?.takeIf { it.isConnected && it.isAuthenticated } ?: connect(host).also { clients[host.id] = it }
        }
        val session = try { client.startSession() } catch (error: IOException) {
            disconnect(host)
            throw RemoteException(error.message ?: "SSH 通道已断开", confirmed = false)
        }
        val running = session.exec(command)
        val errors = StringBuffer()
        thread(isDaemon = true, name = "ssh-stderr") {
            runCatching { running.errorStream.bufferedReader().forEachLine { if (errors.length < 8192) errors.appendLine(it) } }
        }
        return object : RemoteProcess {
            override val stdout: InputStream = running.inputStream
            override val stdin: OutputStream = running.outputStream
            override fun errorText(): String = errors.toString()
            override fun waitForExit(): Int? = runCatching { running.join(60, TimeUnit.SECONDS); running.exitStatus }.getOrNull()
            override fun kill() { runCatching { running.close() }; runCatching { session.close() } }
        }
    }

    private fun connect(host: HostConfig): SSHClient {
        val client = SSHClient(DefaultConfig().apply { keepAliveProvider = KeepAliveProvider.KEEP_ALIVE })
        var offered: String? = null
        client.addHostKeyVerifier(object : HostKeyVerifier {
            override fun verify(hostname: String, port: Int, key: PublicKey): Boolean {
                offered = fingerprint(key)
                return offered == host.hostKey
            }
            override fun findExistingAlgorithms(hostname: String, port: Int): List<String> = emptyList()
        })
        client.connectTimeout = 15_000
        try {
            try { client.connect(host.host, host.port) } catch (error: IOException) {
                val seen = offered
                if (seen != null && seen != host.hostKey) throw if (host.hostKey == null) UnknownHostKeyException(seen) else HostKeyChangedException(seen)
                throw RemoteException("无法连接 ${host.host}:${host.port}：${error.message ?: error.javaClass.simpleName}", confirmed = false)
            }
            client.connection.keepAlive.keepAliveInterval = 15
            val secret = secret(host)
            try {
                if (host.auth == AuthMethod.Key) {
                    val key = secret.privateKey?.takeIf { it.isNotBlank() } ?: throw RemoteException("还没有为这台服务器设置私钥", confirmed = false)
                    client.authPublickey(host.user, client.loadKeys(key, null, secret.passphrase?.takeIf { it.isNotEmpty() }?.let { PasswordUtils.createOneOff(it.toCharArray()) }))
                } else {
                    client.authPassword(host.user, secret.password ?: throw RemoteException("还没有为这台服务器设置密码", confirmed = false))
                }
            } catch (error: UserAuthException) {
                throw RemoteException(if (host.auth == AuthMethod.Key) "服务器拒绝了这个私钥" else "用户名或密码不正确", confirmed = false)
            } catch (error: IOException) {
                throw RemoteException("登录失败：${error.message ?: error.javaClass.simpleName}", confirmed = false)
            }
            return client
        } catch (error: Exception) {
            runCatching { client.close() }
            throw error
        }
    }

    override fun disconnect(host: HostConfig) {
        val client = synchronized(clients) { clients.remove(host.id) }
        if (client != null) thread(isDaemon = true) { runCatching { client.close() } }
    }
}
