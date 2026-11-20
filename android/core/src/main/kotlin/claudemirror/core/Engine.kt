package claudemirror.core

import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * The conversations on this device and their replies on the servers.
 *
 * A reply is produced by a worker process on the server that outlives the SSH connection,
 * so nothing here re-executes a prompt: starting a task is idempotent per task ID, and a
 * dropped connection only detaches the conversation until [restore] rejoins it.
 *
 * Everything runs on [scope], which must use a single-threaded dispatcher.
 */
class Engine(
    private val scope: CoroutineScope,
    private val agents: AgentPool,
    private val store: SessionStore,
    private val host: (String) -> HostConfig?,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private class Watcher(val taskId: String) {
        /** Packets and the final reason, in the order the agent reported them. */
        val events = Channel<Any>(Channel.UNLIMITED)
        var cancel: (() -> Unit)? = null
        var previous: JsonObject? = null
        var killed = false
        // Closing the channel ends its reader: the agent sends nothing more once unsubscribed.
        fun kill() { killed = true; cancel?.invoke(); events.close() }
    }

    private val state = MutableStateFlow(store.load().sortedByDescending { it.updatedAt })
    val sessions: StateFlow<List<ChatSession>> = state

    private val watchers = HashMap<String, Watcher>()
    private val attaching = HashMap<String, Job>()
    private val installs = HashMap<String, Deferred<Unit>>()
    private val stopRequests = HashSet<String>()
    private val unsaved = HashSet<String>()
    private var saving: Job? = null
    private var written: Job? = null
    private val disk = Dispatchers.IO.limitedParallelism(1)

    fun session(id: String): ChatSession? = state.value.firstOrNull { it.id == id }
    private fun require(id: String): ChatSession = session(id) ?: throw RemoteException("对话不存在")
    private fun hostOf(session: ChatSession): HostConfig = host(session.hostId) ?: throw RemoteException("这台服务器已被删除")
    private fun newId() = UUID.randomUUID().toString()

    /** Streaming changes are written at most once a second; the end of a turn is written at once. */
    private fun update(id: String, immediate: Boolean = true, change: (ChatSession) -> ChatSession) {
        state.value = state.value.map { if (it.id == id) change(it) else it }
        unsaved += id
        if (immediate) { saving?.cancel(); flush() }
        else if (saving == null) saving = scope.launch { delay(1000); flush() }
    }

    private fun flush() {
        saving = null
        val changed = unsaved.mapNotNull(::session)
        unsaved.clear()
        if (changed.isEmpty()) return
        written = scope.launch(disk) {
            // A full disk must not take the app down; the conversation stays usable in memory.
            runCatching { changed.forEach(store::save) }.onFailure { onError?.invoke("对话没有保存到手机：" + (it.message ?: it.javaClass.simpleName)) }
        }
    }

    // Conversations

    fun create(host: HostConfig): ChatSession {
        val session = ChatSession(id = newId(), hostId = host.id, directory = host.directory, createdAt = now(), updatedAt = now())
        state.value = listOf(session) + state.value
        update(session.id) { it }
        return session
    }

    fun remove(id: String) {
        val session = session(id) ?: return
        watchers.remove(id)?.kill()
        if (session.remoteTask != null || session.remoteOwner != null) scope.launch { runCatching { command(session, "close") } }
        state.value = state.value.filter { it.id != id }
        unsaved -= id
        scope.launch(disk) { runCatching { store.delete(id) } }
    }

    /** Applies to the next reply. A worker kept alive for this conversation is closed so it restarts with the new settings. */
    suspend fun configure(id: String, preferences: Preferences) {
        val session = require(id)
        if (session.remoteTask != null) throw RemoteException("请等待当前回复完成")
        if (session.remoteOwner != null) {
            command(session, "close")
            watchers.remove(id)?.kill()
        }
        update(id) { it.copy(preferences = preferences, remoteOwner = null) }
    }

    // Sending and the queue

    /** Sends now when Claude is idle. During a reply the message waits in the queue, or with [steer] goes into the running reply. */
    fun submit(id: String, text: String, steer: Boolean = false) {
        if (require(id).remoteTask == null) return send(id, text)
        val item = enqueue(id, text)
        if (steer) scope.launch { runCatching { steer(id, item.id) }.onFailure { onError?.invoke(it.message ?: "插队失败") } }
    }

    var onError: ((String) -> Unit)? = null

    private fun enqueue(id: String, text: String): QueuedMessage {
        val value = text.trim()
        if (value.isEmpty() || text.length > MAX_LENGTH) throw RemoteException("消息不能为空或超过 20 万字符")
        if (require(id).queue.size >= 20) throw RemoteException("最多排队 20 条消息")
        val item = QueuedMessage(newId(), value)
        update(id) { it.copy(queue = it.queue + item) }
        return item
    }

    fun cancelQueued(id: String, item: String) = update(id) { it.copy(queue = it.queue.filter { queued -> queued.id != item }) }
    fun clearQueue(id: String) = update(id) { it.copy(queue = emptyList()) }

    fun resumeQueue(id: String) {
        update(id) { it.copy(queuePaused = false) }
        drainQueue(id)
    }

    private fun drainQueue(id: String) {
        val session = session(id) ?: return
        val item = session.queue.firstOrNull() ?: return
        if (session.remoteTask != null || session.queuePaused) return
        update(id) { it.copy(queue = it.queue.drop(1)) }
        try { send(id, item.text) } catch (error: RemoteException) {
            update(id) { it.copy(queue = listOf(item) + it.queue, queuePaused = true) }
            onError?.invoke(error.message.orEmpty())
        }
    }

    /**
     * Hands a queued message to the running reply; Claude reads it at its next step.
     * A message the worker did not take goes back to the front of the queue.
     */
    suspend fun steer(id: String, item: String) {
        val session = require(id)
        val queued = session.queue.firstOrNull { it.id == item } ?: return
        if (session.remoteTask == null) return resumeQueue(id)
        update(id) { it.copy(queue = it.queue.filter { other -> other.id != item }) }
        try {
            command(session, "steer", commandId = queued.id) { put("id", queued.id); put("text", queued.text); put("prompt", queued.text) }
        } catch (error: RemoteException) {
            // The acknowledgement can be lost after the worker took the message; the transcript then shows it.
            val delivered = session(id)?.messages?.any { message -> message.blocks.orEmpty().any { it.type == "user" && it.id == queued.id && it.cancelled != true } } == true
            if (delivered) return
            update(id) { it.copy(queue = listOf(queued) + it.queue, queuePaused = it.queuePaused || !error.confirmed) }
            throw error
        }
    }

    fun send(id: String, text: String) {
        val session = require(id)
        if (session.remoteTask != null) throw RemoteException("Claude 正在回复，请先停止或等待完成")
        val value = text.trim()
        if (value.isEmpty() || text.length > MAX_LENGTH) throw RemoteException("消息不能为空或超过 20 万字符")
        hostOf(session)
        val reply = ChatMessage(id = newId(), role = "assistant", blocks = emptyList(), createdAt = now().toDouble())
        val owner = session.remoteOwner
        update(id) {
            it.copy(
                name = if (it.messages.isEmpty() && it.name == ChatSession.NEW_NAME) value.take(28) else it.name,
                messages = it.messages + ChatMessage(id = newId(), role = "user", text = value, createdAt = now().toDouble()) + reply,
                status = "connecting", updatedAt = now(), queuePaused = false, transportError = null,
                // Stored before anything is sent: after an unanswered request the same task ID is used again.
                remoteTask = RemoteTask(id = owner?.id ?: newId(), prompt = value, messageId = reply.id, continuation = owner != null),
            )
        }
        // The task ID is on disk before the server hears of it, so a reply started
        // just before the app is killed can still be found afterwards.
        val saved = written
        scope.launch {
            saved?.join()
            if (owner != null) continueTurn(id) else attach(id)
        }
    }

    /** Gives the prompt to the worker that is still alive from the previous reply. */
    private suspend fun continueTurn(id: String) {
        try {
            val session = require(id)
            val original = session.remoteTask?.id
            if (original != null) {
                val status = agents.call(hostOf(session), "task", buildJsonObject { put("operation", "status"); put("taskId", original) }).obj()
                if (status != null && status["done"].truthy && status["hibernated"].truthy) return apply(id, status)
            }
            attach(id)
            val current = require(id)
            val task = current.remoteTask?.takeIf { it.id == original } ?: return
            val message = current.messages.firstOrNull { it.id == task.messageId } ?: return
            command(current, "send", commandId = message.id) {
                put("prompt", task.prompt.orEmpty())
                put("message", MirrorJson.encodeToJsonElement(message))
            }
            update(id) { it.copy(remoteTask = it.remoteTask?.copy(submitted = true)) }
        } catch (error: CancellationException) { throw error } catch (error: Exception) { dispatchFailed(id, error) }
    }

    private fun dispatchFailed(id: String, error: Exception) {
        if ((error as? RemoteException)?.confirmed != true) return detached(id, error.message.orEmpty())
        val task = session(id)?.remoteTask ?: return
        update(id) {
            it.copy(
                messages = it.messages.map { message -> if (message.id == task.messageId) message.copy(error = error.message) else message },
                remoteTask = null, status = "error", queuePaused = true,
            )
        }
    }

    // Following a task

    private suspend fun ensureInstalled(host: HostConfig) {
        val install = installs.getOrPut(host.id) {
            scope.async {
                val digest = agents.resources.bundleDigest
                val status = agents.call(host, "task", buildJsonObject { put("operation", "installed"); put("digest", digest) }).obj()
                if (!status?.get("installed").truthy) {
                    agents.call(host, "task", buildJsonObject { put("operation", "install"); put("digest", digest); put("payload", agents.resources.bundlePayload) }, timeoutMs = 180_000)
                }
            }
        }
        try { install.await() } catch (error: Exception) {
            if (installs[host.id] === install) installs.remove(host.id)
            throw error
        }
    }

    /** Joins the conversation's task on the server, starting it if the server has not seen it yet. */
    suspend fun attach(id: String) {
        attaching[id]?.let { return it.join() }
        val job = scope.launch {
            try { attachOnce(id) } catch (error: CancellationException) { throw error } catch (error: Exception) { detached(id, error.message.orEmpty()) }
        }
        attaching[id] = job
        try { job.join() } finally { attaching.remove(id) }
    }

    private suspend fun attachOnce(id: String) {
        val session = session(id) ?: return
        if ((session.remoteTask == null && session.remoteOwner == null) || watchers[id] != null) return
        val host = hostOf(session)
        ensureInstalled(host)
        val taskId = session.remoteTask?.id ?: session.remoteOwner!!.id
        val messageId = session.remoteTask?.messageId ?: session.remoteOwner?.messageId
        val message = session.messages.firstOrNull { it.id == messageId } ?: session.messages.lastOrNull()
        agents.call(host, "task", buildJsonObject {
            put("operation", "start"); put("taskId", taskId); put("digest", agents.resources.bundleDigest)
            put("request", buildJsonObject {
                put("prompt", session.remoteTask?.prompt.orEmpty())
                put("session", buildJsonObject {
                    put("id", session.id); put("name", session.name); put("host", host.address); put("directory", session.directory)
                    put("createdAt", session.createdAt); put("updatedAt", session.updatedAt); put("status", session.status)
                    put("messages", JsonArray(listOfNotNull(message).map { MirrorJson.encodeToJsonElement(it) }))
                    put("permissions", JsonArray(emptyList())); put("queue", JsonArray(emptyList()))
                    put("preferences", MirrorJson.encodeToJsonElement(session.preferences))
                    session.remoteSessionId?.let { put("remoteSessionId", it) }
                    session.model?.let { put("model", it) }
                })
            })
        })
        update(id) { it.copy(remoteTask = it.remoteTask?.let { task -> if (task.continuation) task else task.copy(submitted = true) }, transportError = null) }
        val watcher = Watcher(taskId)
        watchers[id] = watcher
        // The agent calls back on its reader thread; the channel keeps the packets in order.
        scope.launch {
            for (event in watcher.events) {
                if (event is JsonObject) received(event, id, watcher) else { watchEnded(id, watcher, event as String); break }
            }
        }
        watcher.cancel = agents.channel(host).watchTask(taskId, packet = { watcher.events.trySend(it) }, end = { watcher.events.trySend(it) })
        if (watcher.killed) watcher.cancel?.invoke()
    }

    private fun ownerId(id: String): String? = session(id)?.let { it.remoteOwner?.id ?: it.remoteTask?.id }

    private fun received(packet: JsonObject, id: String, watcher: Watcher) {
        if (watchers[id] !== watcher || ownerId(id) != watcher.taskId || packet["heartbeat"].truthy) return
        try {
            val next = applyStateDelta(watcher.previous, packet)
            watcher.previous = next
            apply(id, next)
        } catch (error: Exception) {
            watcher.kill()
            watchers.remove(id)
            detached(id, error.message.orEmpty())
        }
    }

    private fun watchEnded(id: String, watcher: Watcher, reason: String) {
        if (watchers[id] !== watcher) return
        watchers.remove(id)
        if (ownerId(id) == watcher.taskId) detached(id, reason)
    }

    /** Applies one complete state of the conversation's worker. */
    internal fun apply(id: String, remote: JsonObject) {
        val session = session(id) ?: return
        val task = session.remoteTask
        val ownerVersion = session.remoteOwner?.version ?: task?.version ?: return
        val owner = session.remoteOwner?.id ?: task?.id ?: ""
        val version = runCatching { remote["version"]?.jsonPrimitive?.intOrNull }.getOrNull() ?: 0
        if (version < ownerVersion) return
        val done = remote["done"].truthy
        val reported = remote["status"].string() ?: "working"
        // A worker that has exited cannot still be replying, whatever it last wrote down.
        var status = if (done && reported in ACTIVE) "stopped" else reported
        val messageId = remote["message"].obj()?.get("id").string()

        // The state still describes the previous reply while a new prompt is on its way.
        if (task != null && messageId != task.messageId) {
            if (!done) return
            watchers.remove(id)?.kill()
            if (remote["hibernated"].truthy) {
                // The idle worker was put to sleep; a new one resumes the same Claude session.
                update(id) {
                    it.copy(
                        remoteSessionId = remote["remoteSessionId"].string() ?: it.remoteSessionId, remoteOwner = null,
                        remoteTask = RemoteTask(id = newId(), prompt = task.prompt, messageId = task.messageId),
                    )
                }
                scope.launch { attach(id) }
            } else {
                update(id) {
                    it.copy(
                        messages = it.messages.map { message -> if (message.id == task.messageId) message.copy(error = "远端会话已退出，新消息未执行。请重新发送。") else message },
                        status = "error", queuePaused = true, remoteTask = null, remoteOwner = null,
                    )
                }
            }
            return
        }

        if (session.messages.none { it.id == messageId }) throw RemoteException("远端任务与本地消息不匹配")
        var message = MirrorJson.decodeFromJsonElement<ChatMessage>(remote["message"]!!)
        if (done && status == "stopped") message = message.copy(interrupted = true)
        val turnEnded = done || status in ENDED
        // Until the worker confirms the stop, states it wrote before hearing of it still say "working".
        if (!turnEnded && id in stopRequests && status != "stopping") status = "stopping"
        val permissions = remote["permissions"]?.let { runCatching { MirrorJson.decodeFromJsonElement<List<PermissionRequest>>(it) }.getOrNull() }.orEmpty()
        val delivered = message.blocks.orEmpty().filter { it.type == "user" }.mapNotNull { it.id }.toSet()
        update(id, immediate = turnEnded || permissions.isNotEmpty()) {
            it.copy(
                messages = it.messages.map { local -> if (local.id == messageId) message else local },
                status = status, permissions = permissions, transportError = null,
                remoteSessionId = remote["remoteSessionId"].string() ?: it.remoteSessionId,
                model = remote["model"].string() ?: it.model,
                context = remote["context"]?.takeIf { value -> value != JsonNull }?.let { value -> runCatching { MirrorJson.decodeFromJsonElement<ContextUsage>(value) }.getOrNull() } ?: it.context,
                // A message inserted into the reply is in the transcript now; it must not be sent again.
                queue = it.queue.filter { queued -> queued.id !in delivered },
                queuePaused = it.queuePaused || (turnEnded && status != "idle"),
                remoteTask = if (turnEnded) null else it.remoteTask?.copy(version = version),
                remoteOwner = when {
                    done -> null
                    remote["resident"].truthy -> RemoteOwner(owner, version, messageId)
                    else -> it.remoteOwner?.copy(version = version)
                },
            )
        }
        if (done) {
            watchers.remove(id)?.kill()
            scope.launch { runCatching { agents.call(hostOf(session), "task", buildJsonObject { put("operation", "acknowledge"); put("taskId", owner) }) } }
        }
        if (turnEnded && task != null) drainQueue(id)
    }

    private fun detached(id: String, reason: String) {
        val session = session(id) ?: return
        if (session.remoteTask == null && session.remoteOwner == null) return
        update(id) { it.copy(status = if (it.remoteTask != null) "detached" else it.status, transportError = reason.ifEmpty { null }, queuePaused = true) }
    }

    private suspend fun command(session: ChatSession, kind: String, commandId: String = newId(), fields: JsonObjectBuilder.() -> Unit = {}): JsonElement {
        val owner = session.remoteOwner?.id ?: session.remoteTask?.id ?: throw RemoteException("远端会话已经结束")
        val response = agents.call(hostOf(session), "task", buildJsonObject {
            put("operation", "command"); put("taskId", owner); put("commandId", commandId)
            put("command", buildJsonObject { fields(); put("kind", kind) })
            put("wait", session.remoteOwner != null || kind == "send")
        }).obj()
        if (response?.get("ok") == kotlinx.serialization.json.JsonPrimitive(false)) {
            throw RemoteException(response["error"].string() ?: "远端操作失败", confirmed = !response["uncertain"].truthy)
        }
        return response?.get("value") ?: JsonNull
    }

    /** Rejoins this server's unfinished replies after connecting. Nothing is executed twice. */
    suspend fun restore(host: HostConfig) {
        state.value.filter { it.hostId == host.id && (it.remoteTask != null || it.remoteOwner != null) }.map { session ->
            scope.launch {
                val task = session(session.id)?.remoteTask
                if (task?.continuation == true && !task.submitted) continueTurn(session.id) else attach(session.id)
            }
        }.joinAll()
    }

    /** Stops following this server's replies; they keep running there. */
    fun detach(host: HostConfig) {
        for (session in state.value) {
            if (session.hostId != host.id || (session.remoteTask == null && session.remoteOwner == null)) continue
            watchers.remove(session.id)?.kill()
            detached(session.id, "")
        }
    }

    // Stopping and answering

    suspend fun stop(id: String) {
        val session = require(id)
        if ((session.remoteTask == null && session.remoteOwner == null) || !stopRequests.add(id)) return
        val owner = ownerId(id)
        val message = session.messages.lastOrNull()?.id
        suspend fun stopped(): Boolean {
            repeat(31) { attempt ->
                val current = session(id)
                if (current == null || !current.isBusy || ownerId(id) != owner || current.messages.lastOrNull()?.id != message) return true
                if (attempt < 30) delay(100)
            }
            return false
        }
        try {
            update(id) { if (it.isBusy && it.status != "detached") it.copy(status = "stopping") else it }
            command(session, "stop")
            if (stopped()) return
            // An older worker may accept the interrupt without ending the turn; close that one worker.
            command(session, "close")
            if (!stopped()) throw RemoteException("远端尚未确认停止，请重新连接后检查任务状态", confirmed = false)
        } catch (error: RemoteException) {
            val task = session(id)?.remoteTask
            if (error.confirmed && task != null && !task.submitted && ownerId(id) == owner) {
                // The server never received this prompt, so there is nothing running to stop.
                watchers.remove(id)?.kill()
                update(id) {
                    it.copy(
                        messages = it.messages.map { local -> if (local.id == task.messageId) local.copy(interrupted = true) else local },
                        status = "stopped", remoteTask = null, queuePaused = true, transportError = null,
                    )
                }
                return
            }
            update(id) { if (it.status == "stopping") it.copy(status = if (it.permissions.isEmpty()) "working" else "permission") else it }
            throw error
        } finally { stopRequests.remove(id) }
    }

    /** Answers a permission request or a question from Claude. */
    suspend fun respond(id: String, permission: String, answer: JsonObject) {
        val session = require(id)
        if (session.permissions.none { it.id == permission }) throw RemoteException("该请求已结束")
        command(session, "respond") { put("permissionId", permission); put("answer", answer) }
    }

    private companion object {
        const val MAX_LENGTH = 200_000
        val ACTIVE = setOf("working", "connecting", "permission", "stopping", "detached")
        val ENDED = setOf("idle", "stopped", "error")
    }
}
