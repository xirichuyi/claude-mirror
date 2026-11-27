package claudemirror.core

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.Base64
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.selects.select
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
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
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

/** A login shell on the server with a pseudo-terminal; bytes in both directions, as a terminal sees them. */
interface RemoteTerminal {
    val output: InputStream
    val input: OutputStream
    fun resize(columns: Int, rows: Int)
    fun close()
}

interface Launcher {
    /** Blocks until the command has started. */
    fun start(host: HostConfig, command: String): RemoteProcess
    fun disconnect(host: HostConfig) {}
}

/** The server program this app carries: built by `npm run prepare-server`. */
class ServerResources(
    val agentSource: ByteArray,
    val agentDigest: String,
    val bundleDigest: String,
    val bundlePayload: String,
    /** scripts/install-claude-remote.sh; with `--node-only` it puts Node.js on a server that lacks it. */
    val installScript: ByteArray? = null,
) {
    companion object {
        fun read(open: (String) -> InputStream): ServerResources {
            val manifest = open("manifest.json").use { MirrorJson.parseToJsonElement(it.readBytes().decodeToString()) }.obj()
            val agent = manifest?.get("agentDigest").string()
            val bundle = manifest?.get("bundleDigest").string()
            val payload = manifest?.get("bundlePayload").string()
            if (agent == null || bundle == null || payload == null) throw RemoteException("应用内的服务端程序不完整，请重新构建")
            val installer = runCatching { open("install-claude-remote.sh").use { it.readBytes() } }.getOrNull()
            return ServerResources(open("remote-agent.cjs").use { it.readBytes() }, agent, bundle, payload, installer)
        }
    }
}

fun shellQuote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

private fun script(name: String): String =
    AgentChannel::class.java.getResourceAsStream("/claudemirror/core/$name")!!.use { it.readBytes().decodeToString() }

/** One agent process on one server, spoken to over the command's stdin and stdout: JSON lines, then frames (docs/agent-wire.md). */
class AgentChannel internal constructor(
    private val launcher: Launcher,
    private val host: HostConfig,
    private val resources: ServerResources,
) {
    private class Watch(val packet: (JsonObject) -> Unit, val end: (String) -> Unit)
    private class Upload { val offset = CompletableDeferred<Long>(); val credit = Channel<Int>(Channel.UNLIMITED) }

    private val lock = Any()
    private val pending = HashMap<Int, CompletableDeferred<JsonElement>>()
    private val watches = HashMap<String, Watch>()
    private val uploads = HashMap<Int, Upload>()
    @Volatile private var framed = false
    private var upgradeId = -1
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
        if (!launchInstallingNode()) {
            install()
            if (!launch()) throw RemoteException("远端代理启动失败", confirmed = false)
        }
        // An agent that does not know frames stays on JSON lines.
        runCatching { call("frames", buildJsonObject { put("version", 1) }, upgrade = true) }
        val server = MirrorJson.decodeFromJsonElement<ServerInfo>(call("file", buildJsonObject { put("operation", "hello") }))
        if (!server.nodeSupported) {
            close()
            throw NodeOutdatedException(server.node ?: "未知版本")
        }
        info = server
    }

    /** A server without a usable Node.js gets the app's own copy, then the agent starts as usual. */
    private fun launchInstallingNode(): Boolean = try {
        launch()
    } catch (error: Exception) {
        if (error !is NodeMissingException && error !is NodeOutdatedException) throw error
        if (!installNode()) throw error
        launch()
    }

    private fun installNode(): Boolean {
        val script = resources.installScript ?: return false
        val child = launcher.start(host, "sh -c " + shellQuote("command -v bash >/dev/null 2>&1 || exit 1; exec bash -s -- --node-only 2>&1"))
        return try {
            child.stdin.use { it.write(script) }
            child.stdout.readBytes()
            child.waitForExit() == 0
        } catch (error: IOException) { false } finally { child.kill() }
    }

    /** True once the agent answers, false when its program still has to be uploaded. */
    private fun launch(): Boolean {
        val child = launcher.start(host, startCommand)
        var timedOut = false
        val timer: ScheduledFuture<*> = timers.schedule({ timedOut = true; child.kill() }, 30, TimeUnit.SECONDS)
        var ready = false
        try {
            val input = DataInputStream(BufferedInputStream(child.stdout))
            while (true) {
                val line = line(input)?.trim() ?: throw IOException()
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
                                while (true) {
                                    if (!framed) { receive(line(input) ?: break); continue }
                                    val length = input.readInt()
                                    if (length < 5 || length > MAX_FRAME) throw IOException()
                                    val type = input.readByte().toInt()
                                    val id = input.readInt()
                                    frame(type, id, ByteArray(length - 5).also(input::readFully))
                                }
                                child.errorText().trim()
                            } catch (error: IOException) { "" }
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

    private fun line(input: InputStream): String? {
        val bytes = ByteArrayOutputStream()
        while (true) {
            val byte = input.read()
            if (byte < 0) return if (bytes.size() == 0) null else String(bytes.toByteArray(), Charsets.UTF_8)
            if (byte == '\n'.code) return String(bytes.toByteArray(), Charsets.UTF_8)
            bytes.write(byte)
        }
    }

    private fun frame(type: Int, id: Int, payload: ByteArray) {
        when (type) {
            FRAME_JSON -> receive(payload.decodeToString())
            FRAME_BLOB -> {
                val size = ByteBuffer.wrap(payload).int
                val message = runCatching { MirrorJson.parseToJsonElement(payload.decodeToString(4, 4 + size)) }.getOrNull().obj() ?: return
                val result = message["result"].obj() ?: return handle(message)
                val inline = Base64.getEncoder().encodeToString(payload.copyOfRange(4 + size, payload.size))
                handle(JsonObject(message + ("result" to JsonObject(result + ("inlineData" to JsonPrimitive(inline))))))
            }
            FRAME_CREDIT -> synchronized(lock) { uploads[id] }?.credit?.trySend(ByteBuffer.wrap(payload).int)
        }
    }

    private fun receive(line: String) {
        handle(runCatching { MirrorJson.parseToJsonElement(line) }.getOrNull().obj() ?: return)
    }

    private fun handle(message: JsonObject) {
        if (message["event"] != null) return
        message["stream"]?.let { stream ->
            val id = runCatching { stream.jsonPrimitive.intOrNull }.getOrNull()
            val offset = runCatching { message["offset"]?.jsonPrimitive?.longOrNull }.getOrNull() ?: 0L
            synchronized(lock) { uploads[id] }?.offset?.complete(offset)
            return
        }
        val subscription = message["sub"].string()
        if (subscription != null) {
            val ended = message["end"].truthy
            val watch = synchronized(lock) { if (ended) watches.remove(subscription) else watches[subscription] } ?: return
            if (ended) watch.end(message["error"].string().orEmpty())
            else message["packet"].obj()?.let(watch.packet)
            return
        }
        val id = runCatching { message["id"]?.jsonPrimitive?.intOrNull }.getOrNull() ?: return
        // Switched here, before whoever waits for this reply can write again.
        if (id == upgradeId && message["result"].obj()?.get("version")?.jsonPrimitive?.intOrNull == 1) framed = true
        val request = synchronized(lock) { pending.remove(id) } ?: return
        val error = message["error"].string()
        if (error != null) request.completeExceptionally(RemoteException(error))
        else request.complete(message["result"] ?: JsonNull)
    }

    private fun write(value: JsonObject) =
        send(if (framed) frameBytes(FRAME_JSON, 0, value.toString().toByteArray()) else (value.toString() + "\n").toByteArray())

    private fun send(line: ByteArray) {
        val child = synchronized(lock) { process } ?: return
        writer.execute {
            try { child.stdin.write(line); child.stdin.flush() }
            catch (error: IOException) { shutdown("SSH 通道已断开") }
        }
    }

    suspend fun call(op: String, params: JsonObject, timeoutMs: Long = 60_000, upgrade: Boolean = false): JsonElement {
        val request = CompletableDeferred<JsonElement>()
        val id = synchronized(lock) {
            if (closed) throw RemoteException("SSH 通道已断开", confirmed = false)
            sequence += 1
            pending[sequence] = request
            if (upgrade) upgradeId = sequence
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

    /**
     * Sends a file as `file`/`write` over this channel, never more than the agent has made room for, so a stop
     * or an approval is not held up behind it. An attachment broken off earlier carries on from where it stopped.
     */
    suspend fun write(request: JsonObject, open: () -> InputStream, sent: (Long) -> Unit): JsonElement = coroutineScope {
        if (!framed) throw RemoteException("远端代理需要更新", confirmed = false)
        val reply = CompletableDeferred<JsonElement>()
        val state = Upload()
        val id = synchronized(lock) {
            if (closed) throw RemoteException("SSH 通道已断开", confirmed = false)
            sequence += 1
            pending[sequence] = reply
            uploads[sequence] = state
            sequence
        }
        var finished = false
        // Tells the agent at once, even while a read of the local file is still blocked.
        val guard = launch(start = CoroutineStart.ATOMIC) { try { awaitCancellation() } finally { if (!finished) write(buildJsonObject { put("cancel", id) }) } }
        try {
            write(buildJsonObject { put("id", id); put("op", "file"); put("params", request) })
            val offset = select<Long?> { state.offset.onAwait { it }; reply.onAwait { null } }
                ?: throw RemoteException("上传失败")
            withContext(Dispatchers.IO) {
                val source = try { open() } catch (error: IOException) { throw RemoteException("无法读取文件") }
                source.use {
                    try {
                        var skipped = 0L
                        while (skipped < offset) skipped += source.skip(offset - skipped).takeIf { it > 0 } ?: throw IOException()
                    } catch (error: IOException) { throw RemoteException("无法读取文件") }
                    var done = offset
                    var credit = 0L
                    sent(done)
                    val chunk = ByteArray(128 * 1024)
                    while (true) {
                        while (credit <= 0) credit += select<Int> {
                            state.credit.onReceive { it }
                            reply.onAwait { throw RemoteException("上传中断", confirmed = false) }
                        }
                        val count = try { source.read(chunk, 0, minOf(credit, chunk.size.toLong()).toInt()) } catch (error: IOException) { throw RemoteException("无法读取文件") }
                        if (count < 0) break
                        credit -= count
                        done += count
                        send(frameBytes(FRAME_DATA, id, chunk.copyOf(count)))
                        sent(done)
                    }
                    send(frameBytes(FRAME_END, id, ByteArray(0)))
                }
            }
            reply.await().also { finished = true }
        } finally {
            guard.cancel()
            synchronized(lock) { pending.remove(id); uploads.remove(id) }
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
        const val FRAME_JSON = 1
        const val FRAME_BLOB = 2
        const val FRAME_DATA = 3
        const val FRAME_END = 4
        const val FRAME_CREDIT = 5
        const val MAX_FRAME = 64 shl 20

        fun frameBytes(type: Int, id: Int, payload: ByteArray): ByteArray =
            ByteBuffer.allocate(9 + payload.size).putInt(5 + payload.size).put(type.toByte()).putInt(id).put(payload).array()

        val timers = Executors.newSingleThreadScheduledExecutor { Thread(it, "agent-timer").apply { isDaemon = true } }
    }
}

sealed interface ConnectionState {
    data object Disconnected : ConnectionState
    data object Connecting : ConnectionState
    data class Connected(val info: ServerInfo) : ConnectionState
    data class Failed(val error: Throwable) : ConnectionState
}

data class RemoteMember(val name: String, val fingerprint: String)

/** Accounts on a shared server, managed through install-claude-remote.sh from a root login. */
object RemoteMembers {
    fun command(arguments: List<String>): String =
        "sh -c " + shellQuote("command -v bash >/dev/null 2>&1 || exit 1; exec bash -s -- " + arguments.joinToString(" ") { shellQuote(it) } + " 2>&1")

    fun parse(lines: List<String>): List<RemoteMember> = lines.mapNotNull { line ->
        val parts = line.split(' ').filter { it.isNotEmpty() }
        if (parts.size >= 3 && parts[0] == "member") RemoteMember(parts[1], if (parts[2] == "-") "" else parts[2]) else null
    }
}

/** One agent per server, started on first use and shared by every conversation on that server. */
class AgentPool(private val launcher: Launcher, val resources: ServerResources) {
    private companion object { const val MAX_UPLOAD = 1L shl 30 }
    // Each upload can have a window of bytes queued ahead of a stop or an approval; two keep that short.
    private val transfers = Semaphore(2)

    /** Output lines of a successful member command; a failure throws its last line. */
    suspend fun members(host: HostConfig, vararg arguments: String): List<String> = withContext(Dispatchers.IO) {
        val script = resources.installScript ?: throw RemoteException("缺少安装脚本")
        val child = launcher.start(host, RemoteMembers.command(arguments.toList()))
        try {
            child.stdin.use { it.write(script) }
            val lines = child.stdout.readBytes().decodeToString().lines()
            if (child.waitForExit() != 0) throw RemoteException(lines.lastOrNull { it.isNotBlank() } ?: "操作失败")
            lines
        } catch (error: IOException) {
            throw RemoteException(error.message ?: "操作失败")
        } finally { child.kill() }
    }

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
     */
    suspend fun upload(host: HostConfig, name: String, size: Long, digest: String, open: () -> InputStream, sent: (Long) -> Unit = {}): Attachment {
        if (size > MAX_UPLOAD) throw RemoteException("文件超过 1 GB")
        val file = name.replace(Regex("[\\x00-\\x1f/\\\\]"), "_").trim().takeUnless { it.isEmpty() || it == "." || it == ".." } ?: "file"
        val known = call(host, "file", buildJsonObject { put("operation", "attachmentLookup"); put("name", file); put("digest", digest) }, 120_000).obj()?.get("file").obj()
        known?.get("path").string()?.let { return Attachment(file, it, size) }
        val request = buildJsonObject {
            put("operation", "write"); put("name", file); put("size", size); put("attachment", true); put("digest", digest)
        }
        val path = transfers.withPermit { channel(host).write(request, open, sent) }.obj()?.get("path").string() ?: throw RemoteException("上传失败")
        return Attachment(file, path, size)
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
