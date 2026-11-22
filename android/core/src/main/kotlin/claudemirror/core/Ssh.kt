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
class SshLauncher(
    /** How long the server may stay silent while the connection is being set up. */
    private val handshakeTimeoutMs: Int = 20_000,
    private val secret: (HostConfig) -> SshSecret,
) : Launcher {
    // Guarded by `clients`. Only map lookups happen under that lock, never network work.
    private val clients = HashMap<String, SSHClient>()
    private val gates = HashMap<String, Any>()
    /** Counts disconnects per server, so a connection attempt overtaken by one is thrown away. */
    private val epochs = HashMap<String, Int>()

    private fun cancelled() = RemoteException("连接已取消", confirmed = false)

    private fun client(host: HostConfig): SSHClient {
        val epoch: Int
        val gate = synchronized(clients) {
            epoch = epochs[host.id] ?: 0
            gates.getOrPut(host.id) { Any() }
        }
        // One connection attempt per server at a time; other servers and disconnects are not held up.
        synchronized(gate) {
            synchronized(clients) {
                if ((epochs[host.id] ?: 0) != epoch) throw cancelled()
                clients[host.id]?.takeIf { it.isConnected && it.isAuthenticated }?.let { return it }
            }
            val fresh = connect(host)
            synchronized(clients) {
                if ((epochs[host.id] ?: 0) == epoch) {
                    clients[host.id] = fresh
                    return fresh
                }
            }
            runCatching { fresh.close() }
            throw cancelled()
        }
    }

    override fun start(host: HostConfig, command: String): RemoteProcess {
        val client = client(host)
        // A connection that went away since it was looked up is refused by the library with an IllegalStateException.
        val session = try { client.startSession() } catch (error: Exception) {
            if (error !is IOException && error !is IllegalStateException) throw error
            val stale = synchronized(clients) { if (clients[host.id] === client) clients.remove(host.id) else null }
            runCatching { stale?.close() }
            throw RemoteException("SSH 通道已断开", confirmed = false)
        }
        val running = try { session.exec(command) } catch (error: Exception) {
            runCatching { session.close() }
            if (error !is IOException && error !is IllegalStateException) throw error
            throw RemoteException("SSH 通道已断开", confirmed = false)
        }
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
        // Without this a server that accepts the connection and then says nothing is waited for forever.
        client.timeout = handshakeTimeoutMs
        try {
            try { client.connect(host.host, host.port) } catch (error: IOException) {
                val seen = offered
                if (seen != null && seen != host.hostKey) throw if (host.hostKey == null) UnknownHostKeyException(seen) else HostKeyChangedException(seen)
                val why = when (error) {
                    is java.net.UnknownHostException -> "找不到主机"
                    is java.net.SocketTimeoutException -> "超时"
                    is java.net.ConnectException -> "被拒绝"
                    else -> null
                }
                throw RemoteException("无法连接 ${host.host}:${host.port}" + (why?.let { "：$it" } ?: ""), confirmed = false)
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
                throw RemoteException("登录失败", confirmed = false)
            }
            // Once logged in, quiet periods are normal; keep-alives notice a dead connection.
            client.socket.soTimeout = 0
            return client
        } catch (error: Exception) {
            runCatching { client.close() }
            throw error
        }
    }

    /** Returns at once: closing the connection happens in the background. */
    override fun disconnect(host: HostConfig) {
        val client = synchronized(clients) {
            epochs[host.id] = (epochs[host.id] ?: 0) + 1
            clients.remove(host.id)
        }
        if (client != null) thread(isDaemon = true, name = "ssh-close") { runCatching { client.close() } }
    }
}
