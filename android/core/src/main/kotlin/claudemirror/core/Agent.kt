package claudemirror.core

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** A command running on the server. All calls block. */
interface RemoteProcess {
    val stdout: InputStream
    val stdin: OutputStream
    fun errorText(): String
    /** The exit status, or null when the command was cut off. */
    fun waitForExit(): Int?
    fun kill()
}

interface Launcher {
    /** Blocks until the command has started. */
    fun start(host: HostConfig, command: String): RemoteProcess
    fun disconnect(host: HostConfig) {}
}

/** The server program this app carries: built by `npm run prepare-server`. */
class ServerResources(val agentSource: ByteArray, val agentDigest: String, val bundleDigest: String, val bundlePayload: String) {
    companion object {
        fun read(open: (String) -> InputStream): ServerResources {
            val manifest = open("manifest.json").use { MirrorJson.parseToJsonElement(it.readBytes().decodeToString()) }.obj()
            val agent = manifest?.get("agentDigest").string()
            val bundle = manifest?.get("bundleDigest").string()
            val payload = manifest?.get("bundlePayload").string()
            if (agent == null || bundle == null || payload == null) throw RemoteException("应用内的服务端程序不完整，请重新构建")
            return ServerResources(open("remote-agent.cjs").use { it.readBytes() }, agent, bundle, payload)
        }
    }
}

fun shellQuote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

private fun script(name: String): String =
    AgentChannel::class.java.getResourceAsStream("/claudemirror/core/$name")!!.use { it.readBytes().decodeToString() }

/** One agent process on one server, spoken to in JSON lines over the command's stdin and stdout. */
class AgentChannel internal constructor(
    private val launcher: Launcher,
    private val host: HostConfig,
    private val resources: ServerResources,
) {
    private class Watch(val packet: (JsonObject) -> Unit, val end: (String) -> Unit)

    private val lock = Any()
    private val pending = HashMap<Int, CompletableDeferred<JsonElement>>()
    private val watches = HashMap<String, Watch>()
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "agent-write").apply { isDaemon = true } }
    private var process: RemoteProcess? = null
    private var sequence = 0
    private var closed = false

    @Volatile var info: ServerInfo? = null
        private set
    @Volatile internal var onClosed: ((String) -> Unit)? = null

    private val agentFile = "\$HOME/.local/share/remotecc/agent/${resources.agentDigest}/remote-agent.cjs"

    // The outer `sh -c` keeps this valid when the account's login shell is fish or csh.
    private val startCommand: String
        get() {
            val bootstrap = shellQuote(script("bootstrap.sh").replace("@AGENT@", agentFile))
            return "sh -c " + shellQuote("if command -v bash >/dev/null 2>&1; then exec bash -lc $bootstrap; else exec sh -lc $bootstrap; fi")
        }

    private val installCommand: String
        get() = "sh -c " + shellQuote(script("install.sh").trim().replace("@AGENT@", agentFile).replace("@SIZE@", resources.agentSource.size.toString()))

    internal suspend fun start() = withContext(Dispatchers.IO) {
        if (!launch()) {
            install()
            if (!launch()) throw RemoteException("远端代理启动失败", confirmed = false)
        }
        val server = MirrorJson.decodeFromJsonElement<ServerInfo>(call("file", buildJsonObject { put("operation", "hello") }))
        if (!server.nodeSupported) {
            close()
            throw NodeOutdatedException(server.node ?: "未知版本")
        }
        info = server
    }

    /** True once the agent answers, false when its program still has to be uploaded. */
    private fun launch(): Boolean {
        val child = launcher.start(host, startCommand)
        var timedOut = false
        val timer: ScheduledFuture<*> = timers.schedule({ timedOut = true; child.kill() }, 30, TimeUnit.SECONDS)
        var ready = false
        try {
            val reader = child.stdout.bufferedReader()
            while (true) {
                val line = reader.readLine()?.trim() ?: throw IOException()
                when {
                    line == "__RCC_INSTALL__" -> return false
                    line == "__RCC_NO_NODE__" -> throw NodeMissingException()
                    line.startsWith("__RCC_OLD_NODE__ ") -> throw NodeOutdatedException(line.removePrefix("__RCC_OLD_NODE__ "))
                    line.startsWith("{\"rcc\":\"ready\"") -> {
                        // Closed while the command was starting: nobody is waiting for this agent any more.
                        synchronized(lock) { if (closed) throw IOException() else process = child }
                        ready = true
                        thread(isDaemon = true, name = "agent-read") {
                            val reason = try {
                                reader.forEachLine(::receive)
                                child.errorText().trim()
                            } catch (error: IOException) { error.message.orEmpty() }
                            shutdown(reason.ifEmpty { "SSH 通道已断开" })
                        }
                        return true
                    }
                }
            }
        } catch (error: IOException) {
            throw RemoteException(if (timedOut) "远端代理启动超时" else child.errorText().trim().ifEmpty { "远端代理已退出" }, confirmed = false)
        } finally {
            timer.cancel(false)
            if (!ready) child.kill()
        }
    }

    private fun install() {
        val child = launcher.start(host, installCommand)
        try {
            child.stdin.use { it.write(resources.agentSource) }
            if (child.waitForExit() != 0) throw RemoteException(child.errorText().trim().ifEmpty { "无法安装远端代理" })
        } catch (error: IOException) {
            throw RemoteException(child.errorText().trim().ifEmpty { "无法安装远端代理" })
        } finally { child.kill() }
    }

    private fun receive(line: String) {
        val message = runCatching { MirrorJson.parseToJsonElement(line) }.getOrNull().obj() ?: return
        if (message["event"] != null) return
        val subscription = message["sub"].string()
        if (subscription != null) {
            val ended = message["end"].truthy
            val watch = synchronized(lock) { if (ended) watches.remove(subscription) else watches[subscription] } ?: return
            if (ended) watch.end(message["error"].string().orEmpty())
            else message["packet"].obj()?.let(watch.packet)
            return
        }
        val id = runCatching { message["id"]?.jsonPrimitive?.intOrNull }.getOrNull() ?: return
        val request = synchronized(lock) { pending.remove(id) } ?: return
        val error = message["error"].string()
        if (error != null) request.completeExceptionally(RemoteException(error))
        else request.complete(message["result"] ?: JsonNull)
    }

    private fun write(value: JsonObject) {
        val child = synchronized(lock) { process } ?: return
        val line = (value.toString() + "\n").toByteArray()
        writer.execute {
            try { child.stdin.write(line); child.stdin.flush() }
            catch (error: IOException) { shutdown(error.message ?: "SSH 通道已断开") }
        }
    }

    suspend fun call(op: String, params: JsonObject, timeoutMs: Long = 60_000): JsonElement {
        val request = CompletableDeferred<JsonElement>()
        val id = synchronized(lock) {
            if (closed) throw RemoteException("SSH 通道已断开", confirmed = false)
            sequence += 1
            pending[sequence] = request
            sequence
        }
        write(buildJsonObject { put("id", id); put("op", op); put("params", params) })
        try {
            return withTimeout(timeoutMs) { request.await() }
        } catch (error: CancellationException) {
            if (synchronized(lock) { pending.remove(id) } != null) write(buildJsonObject { put("cancel", id) })
            if (error is TimeoutCancellationException) throw RemoteException("远端操作超时", confirmed = false)
            throw error
        }
    }

    /** Follows a task's state. The returned function stops following it. Callbacks arrive in order on one thread. */
    fun watchTask(taskId: String, packet: (JsonObject) -> Unit, end: (String) -> Unit): () -> Unit {
        val subscription = UUID.randomUUID().toString()
        val id = synchronized(lock) {
            if (closed) null else {
                watches[subscription] = Watch(packet, end)
                sequence += 1
                sequence
            }
        }
        if (id == null) { end("SSH 通道已断开"); return {} }
        write(buildJsonObject {
            put("id", id); put("op", "taskWatch")
            put("params", buildJsonObject { put("taskId", taskId); put("subscription", subscription) })
        })
        return {
            if (synchronized(lock) { watches.remove(subscription) } != null) write(buildJsonObject { put("cancel", "sub:$subscription") })
        }
    }

    private fun shutdown(reason: String) {
        val requests: List<CompletableDeferred<JsonElement>>
        val ended: List<Watch>
        val child: RemoteProcess?
        synchronized(lock) {
            if (closed) return
            closed = true
            requests = pending.values.toList(); pending.clear()
            ended = watches.values.toList(); watches.clear()
            child = process; process = null
        }
        writer.shutdown()
        // Closing an SSH channel talks to the server, and the caller may be the UI thread.
        if (child != null) thread(isDaemon = true, name = "agent-close") { child.kill() }
        requests.forEach { it.completeExceptionally(RemoteException(reason, confirmed = false)) }
        ended.forEach { it.end(reason) }
        onClosed?.invoke(reason)
    }

    fun close() = shutdown("连接已关闭")

    private companion object {
        val timers = Executors.newSingleThreadScheduledExecutor { Thread(it, "agent-timer").apply { isDaemon = true } }
    }
}

sealed interface ConnectionState {
    data object Disconnected : ConnectionState
    data object Connecting : ConnectionState
    data class Connected(val info: ServerInfo) : ConnectionState
    data class Failed(val error: Throwable) : ConnectionState
}

/** One agent per server, started on first use and shared by every conversation on that server. */
class AgentPool(private val launcher: Launcher, val resources: ServerResources) {
    private companion object { const val MAX_UPLOAD = 1L shl 30 }
    private val transfers = Semaphore(2)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val channels = HashMap<String, Deferred<AgentChannel>>()
    private val _states = MutableStateFlow<Map<String, ConnectionState>>(emptyMap())
    val states: StateFlow<Map<String, ConnectionState>> = _states

    private fun state(host: HostConfig, value: ConnectionState) = _states.update { it + (host.id to value) }

    suspend fun channel(host: HostConfig): AgentChannel {
        val starting = synchronized(channels) {
            channels[host.id] ?: run {
                val channel = AgentChannel(launcher, host, resources)
                val attempt = scope.async(start = CoroutineStart.LAZY) {
                    // An attempt given up half way must not leave its agent running.
                    try { channel.start() } catch (error: Throwable) { channel.onClosed = null; channel.close(); throw error }
                    channel
                }
                channel.onClosed = { forget(host, null, attempt) }
                channels[host.id] = attempt
                state(host, ConnectionState.Connecting)
                attempt.invokeOnCompletion { error ->
                    if (error == null) {
                        // The channel may have closed before this ran; forget() then already reported it.
                        if (synchronized(channels) { channels[host.id] === attempt }) state(host, ConnectionState.Connected(channel.info!!))
                    } else forget(host, error, attempt)
                }
                attempt.start()
                attempt
            }
        }
        return starting.await()
    }

    /** Only the attempt that is still the server's current one may change what is shown for it. */
    private fun forget(host: HostConfig, error: Throwable?, attempt: Deferred<AgentChannel>) {
        synchronized(channels) {
            if (channels[host.id] !== attempt) return
            channels.remove(host.id)
        }
        state(host, if (error == null || error is CancellationException) ConnectionState.Disconnected else ConnectionState.Failed(error))
    }

    suspend fun call(host: HostConfig, op: String, params: JsonObject, timeoutMs: Long = 60_000): JsonElement =
        channel(host).call(op, params, timeoutMs)

    /**
     * Puts a file where Claude can read it and says where that is. It is kept under what it
     * contains ([digest], SHA-256), so a file the server already has is not sent again.
     * The bytes travel on a channel of their own and never hold up a stop or an approval.
     */
    suspend fun upload(host: HostConfig, name: String, size: Long, digest: String, open: () -> InputStream, sent: (Long) -> Unit = {}): Attachment {
        if (size > MAX_UPLOAD) throw RemoteException("文件超过 1 GB")
        val file = name.replace(Regex("[\\x00-\\x1f/\\\\]"), "_").trim().takeUnless { it.isEmpty() || it == "." || it == ".." } ?: "file"
        val known = call(host, "file", buildJsonObject { put("operation", "attachmentLookup"); put("name", file); put("digest", digest) }, 120_000).obj()?.get("file").obj()
        known?.get("path").string()?.let { return Attachment(file, it, size) }
        val server = channel(host).info?.takeIf { it.nodePath.isNotEmpty() && it.agentPath.isNotEmpty() } ?: throw RemoteException("SSH 通道已断开", confirmed = false)
        val request = buildJsonObject {
            put("operation", "upload"); put("name", file); put("size", size); put("attachment", true); put("digest", digest)
        }
        val command = "${shellQuote(server.nodePath)} ${shellQuote(server.agentPath)} transfer ${shellQuote(request.toString())}"
        // A server allows only so many commands on one connection (sshd's MaxSessions, 10 unless changed).
        return transfers.withPermit {
            coroutineScope {
                val process = withContext(Dispatchers.IO) { launcher.start(host, command) }
                // The reads and writes below only end early when the command under them does. Ending it
                // talks to the server, which the caller's thread (the main one, in the app) may not do.
                val guard = launch(Dispatchers.IO, start = CoroutineStart.ATOMIC) { try { awaitCancellation() } finally { process.kill() } }
                try {
                    withContext(Dispatchers.IO) {
                        try {
                            var done = 0L
                            val source = try { open() } catch (error: IOException) { throw RemoteException("无法读取文件") }
                            source.use {
                                val chunk = ByteArray(64 * 1024)
                                while (true) {
                                    val count = try { source.read(chunk) } catch (error: IOException) { throw RemoteException("无法读取文件") }
                                    if (count < 0) break
                                    process.stdin.write(chunk, 0, count)
                                    done += count
                                    sent(done)
                                }
                            }
                            process.stdin.close()
                            val answer = process.stdout.readBytes().decodeToString()
                            if (process.waitForExit() != 0) throw RemoteException(process.errorText().trim().ifEmpty { "上传失败" })
                            val path = runCatching { MirrorJson.parseToJsonElement(answer).obj()?.get("path").string() }.getOrNull()
                            Attachment(file, path ?: throw RemoteException("上传失败"), size)
                        } catch (error: IOException) {
                            // Taken back by the caller: nothing failed.
                            ensureActive()
                            // The command gave up first, and says why once it has ended.
                            runCatching { process.stdin.close() }
                            process.waitForExit()
                            throw RemoteException(process.errorText().trim().ifEmpty { error.message ?: "上传失败" }, confirmed = false)
                        }
                    }
                } finally { guard.cancel() }
            }
        }
    }

    /** Drops the connection. Replies being produced on the server keep running there. */
    fun close(host: HostConfig) {
        val attempt = synchronized(channels) { channels.remove(host.id) }
        if (attempt != null) {
            if (attempt.isCompleted && attempt.getCompletionExceptionOrNull() == null) attempt.getCompleted().close() else attempt.cancel()
        }
        launcher.disconnect(host)
        state(host, ConnectionState.Disconnected)
    }
}
