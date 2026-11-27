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
import kotlinx.serialization.json.JsonPrimitive
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

    fun create(host: HostConfig, directory: String = host.directory): ChatSession =
        added(ChatSession(id = newId(), hostId = host.id, directory = directory, createdAt = now(), updatedAt = now()))

    private fun added(session: ChatSession): ChatSession {
        state.value = listOf(session) + state.value
        update(session.id) { it }
        return session
    }

    fun rename(id: String, name: String) {
        val value = name.trim().take(80)
        if (value.isNotEmpty()) update(id) { it.copy(name = value) }
    }

    // What is already on the server

    /** The folders inside [path] on the server. */
    suspend fun folders(host: HostConfig, path: String): RemoteListing {
        val result = agents.call(host, "file", buildJsonObject { put("operation", "list"); put("path", path) })
        val listing = MirrorJson.decodeFromJsonElement<RemoteListing>(result)
        return listing.copy(entries = listing.entries.filter { it.directory })
    }

    /** The conversations Claude Code keeps on the server, newest first. */
    suspend fun history(host: HostConfig): List<RemoteConversation> {
        val found = ArrayList<RemoteConversation>()
        var offset: JsonElement = JsonPrimitive(0)
        // 200 a page; beyond a couple of thousand nobody scrolls on a phone.
        repeat(10) {
            val page = agents.call(host, "history", buildJsonObject { put("operation", "list"); put("offset", offset) }).obj() ?: return found
            page.list("sessions").mapNotNullTo(found) { runCatching { MirrorJson.decodeFromJsonElement<RemoteConversation>(it) }.getOrNull() }
            offset = page["nextOffset"]?.takeIf { it.string() != null } ?: return found
        }
        return found
    }

    private suspend fun transcript(host: HostConfig, reference: String, before: String? = null): JsonObject =
        agents.call(host, "history", buildJsonObject {
            put("operation", "messages"); put("reference", reference)
            if (before != null) put("before", before)
        }).obj() ?: throw RemoteException("服务器没有返回对话")

    /** Opens a conversation from the server here, so it can be continued from the phone. */
    suspend fun adopt(host: HostConfig, item: RemoteConversation): ChatSession {
        fun known() = state.value.firstOrNull { it.hostId == host.id && it.remoteSessionId == item.sessionId }
        known()?.let { return it }
        val reply = transcript(host, item.reference)
        val page = historyPage(reply.list("records"))
        val directory = reply["directory"].string()?.takeIf { it.startsWith("/") } ?: throw RemoteException("这个对话没有记录工作目录")
        known()?.let { return it }
        val time = if (item.updatedAt > 0) item.updatedAt.toLong() else now()
        return added(ChatSession(
            id = newId(), hostId = host.id, name = historyTitle(item.name), directory = directory, createdAt = time, updatedAt = time,
            messages = page.messages, remoteSessionId = item.sessionId, historyRef = item.reference,
            historyBefore = reply["before"].string(), historyTail = page.messages.lastOrNull()?.id, historyLoose = page.loose,
        ))
    }

    /** Loads the part of an adopted conversation that comes before what is shown. */
    suspend fun loadEarlier(id: String) {
        val session = require(id)
        val reference = session.historyRef ?: return
        val before = session.historyBefore ?: return
        val reply = transcript(hostOf(session), reference, before)
        val page = historyPage(reply.list("records"))
        update(id) { current ->
            if (current.historyBefore != before) return@update current
            val shown = current.messages.mapTo(HashSet()) { it.id }
            val called = page.messages.flatMapTo(HashSet()) { message -> message.blocks.orEmpty().filter { it.type == "tool" }.map { it.id } }
            current.copy(
                messages = page.messages.answered(current.historyLoose).filter { it.id !in shown } + current.messages,
                // A result whose call is further back still is kept for the page that has it.
                historyBefore = reply["before"].string(), historyLoose = page.loose + current.historyLoose.filter { it.id !in called },
            )
        }
    }

    /**
     * Picks up what was said elsewhere (in a terminal, on the Mac) since an adopted conversation
     * was last shown. Left alone while a reply is running here: then this app is the one writing.
     */
    suspend fun refresh(id: String) {
        val original = require(id)
        val reference = original.historyRef ?: return
        if (original.remoteTask != null) return
        val shown = original.messages.mapTo(HashSet()) { it.id }
        // Back from the end until something shown turns up, so that what is new joins on without a gap.
        var records = emptyList<JsonElement>()
        var before: String? = null
        val asked = HashSet<String?>()
        while (asked.add(before) && asked.size <= 20) {
            val reply = transcript(hostOf(original), reference, before)
            val batch = reply.list("records")
            records = batch + records
            before = reply["before"].string()
            if (before == null || batch.any { it.obj()?.get("uuid").string() in shown }) break
        }
        val page = historyPage(records)
        val incoming = page.messages
        if (incoming.isEmpty()) return

        // What was said here follows the transcript's last message and carries other IDs than
        // Claude gives it. Until the transcript has it, the transcript is behind and is not shown.
        val said = original.messages.drop(original.messages.indexOfLast { it.id == original.historyTail } + 1)
        // Only what the transcript gained since counts: an older prompt with the same words proves nothing.
        val news = incoming.drop(incoming.indexOfLast { it.id == original.historyTail } + 1)
        // Each of the transcript's prompts stands for one said here, however many share its words.
        val arrived = HashMap<String?, Int>()
        for (message in news) if (message.role == "user") arrived.merge(message.text, 1, Int::plus)
        fun reached(prompt: ChatMessage) = (arrived[prompt.text] ?: 0) > 0 && arrived.merge(prompt.text, -1, Int::plus) != null
        fun ChatMessage.failed() = role == "assistant" && error != null && blocks.isNullOrEmpty()
        val (doubtful, sure) = said.withIndex().filter { it.value.role == "user" }.partition { said.getOrNull(it.index + 1)?.failed() == true }
        // A prompt that was answered is in the transcript, or the transcript is behind and is not shown.
        if (sure.any { !reached(it.value) }) return
        // A prompt whose reply failed before it began, and that the transcript does not have,
        // never reached Claude: it is not waited for, and it stays, at the end.
        val unsent = doubtful.filter { !reached(it.value) }.flatMap { listOf(it.value, said[it.index + 1]) }
        val first = incoming.indexOfFirst { it.id in shown }
        // Nothing in common: the latest part replaces what is shown.
        val kept = if (first < 0) emptyList() else original.messages.take(original.messages.indexOfFirst { it.id == incoming[first].id })
        val merged = kept.answered(page.loose) + incoming.drop(maxOf(first, 0)) + unsent
        if (merged == original.messages) return

        val owner = original.remoteOwner
        if (owner != null) {
            // The worker kept alive for this conversation remembers only what was said here. While
            // nothing else was said it stays; once something was, the next prompt needs a worker
            // that reads the transcript again.
            // Counted, not looked up: the same words typed elsewhere are one prompt more than was said here.
            val here = HashMap<String?, Int>()
            for (message in said) {
                if (message.role == "user") here.merge(message.text, 1, Int::plus)
                else for (block in message.blocks.orEmpty()) if (block.type == "user") here.merge(block.text, 1, Int::plus)
            }
            if (news.none { it.role == "user" && here.merge(it.text, -1, Int::plus)!! < 0 }) return
            // Let go of the worker before telling it to close: a prompt sent in the meantime
            // starts a new worker instead of reaching one that is on its way out.
            val free = session(id)?.let { it.remoteTask == null && it.messages == original.messages && it.remoteOwner?.id == owner.id } == true
            if (!free) return
            update(id) { it.copy(remoteOwner = null) }
            watchers.remove(id)?.kill()
            // If this fails the worker lingers until it tires of waiting; nothing reaches it any more.
            try { command(original, "close") } catch (error: CancellationException) { throw error } catch (_: Exception) {}
        }
        update(id) { current ->
            val moved = current.remoteTask != null || current.messages != original.messages || (current.remoteOwner != null && current.remoteOwner.id != owner?.id)
            if (moved) current
            else if (first < 0) current.copy(messages = merged, remoteOwner = null, historyBefore = before, historyLoose = page.loose, historyTail = incoming.last().id, updatedAt = now())
            else current.copy(messages = merged, remoteOwner = null, historyTail = incoming.last().id, updatedAt = now())
        }
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

    private val catalogue = MutableStateFlow<Map<String, List<RemoteModel>>>(emptyMap())
    /** The models each server offers, by host ID, once known. */
    val models: StateFlow<Map<String, List<RemoteModel>>> = catalogue

    private fun offered(host: String, capabilities: JsonElement?) {
        val list = capabilities.obj()?.get("models")?.let { runCatching { MirrorJson.decodeFromJsonElement<List<RemoteModel>>(it) }.getOrNull() }
        if (!list.isNullOrEmpty()) catalogue.value = catalogue.value + (host to list)
    }

    /** Asks the server which models it offers, unless a reply has already told. */
    suspend fun loadModels(id: String) {
        val session = require(id)
        val host = hostOf(session)
        if (host.id in catalogue.value) return
        ensureInstalled(host)
        offered(host.id, agents.call(host, "task", buildJsonObject {
            put("operation", "inspect"); put("digest", agents.resources.bundleDigest); put("action", "catalogue")
            put("directory", session.directory); put("preferences", MirrorJson.encodeToJsonElement(session.preferences))
        }))
        if (host.id !in catalogue.value) throw RemoteException("服务器没有返回模型")
    }

    // Sending and the queue

    /** Sends now when Claude is idle. During a reply the message waits in the queue, or with [steer] goes into the running reply. */
    fun submit(id: String, text: String, attachments: List<Attachment> = emptyList(), steer: Boolean = false) {
        if (require(id).remoteTask == null) return send(id, text, attachments)
        val item = enqueue(id, text, attachments)
        if (steer) scope.launch { runCatching { steer(id, item.id) }.onFailure { onError?.invoke(it.message ?: "插队失败") } }
    }

    var onError: ((String) -> Unit)? = null

    private fun enqueue(id: String, text: String, attachments: List<Attachment>): QueuedMessage {
        val value = said(text, attachments)
        if (require(id).queue.size >= 20) throw RemoteException("最多排队 20 条消息")
        val item = QueuedMessage(newId(), value, attachments)
        update(id) { it.copy(queue = it.queue + item) }
        return item
    }

    /** The hold belongs to the messages that were waiting when the server moved; it ends with the last of them. */
    /** A reply nobody is writing any more: whatever it was still running did not finish here. */
    private fun ChatMessage.cutShort() = settled().copy(interrupted = true)

    private fun ChatMessage.settled() = copy(
        blocks = blocks?.map { block ->
            block.copy(
                status = if (block.status == "running") "stopped" else block.status,
                children = block.children?.map { if (it.status == "running") it.copy(status = "stopped") else it },
            )
        },
    )

    private fun ChatSession.withQueue(queue: List<QueuedMessage>) = copy(queue = queue, queueHeld = queueHeld && queue.isNotEmpty())

    fun cancelQueued(id: String, item: String) = update(id) { it.withQueue(it.queue.filter { queued -> queued.id != item }) }
    fun clearQueue(id: String) = update(id) { it.withQueue(emptyList()) }

    fun resumeQueue(id: String) {
        update(id) { it.copy(queuePaused = false, queueHeld = false) }
        drainQueue(id)
    }

    private fun drainQueue(id: String) {
        val session = session(id) ?: return
        val item = session.queue.firstOrNull() ?: return
        if (session.remoteTask != null || session.queuePaused || session.queueHeld) return
        update(id) { it.copy(queue = it.queue.drop(1)) }
        try { send(id, item.text, item.attachments) } catch (error: RemoteException) {
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
        update(id) { it.withQueue(it.queue.filter { other -> other.id != item }) }
        try {
            command(session, "steer", commandId = queued.id) { 
                put("id", queued.id); put("text", queued.text); put("prompt", prompt(queued.text, queued.attachments))
                if (queued.attachments.isNotEmpty()) put("attachments", MirrorJson.encodeToJsonElement(queued.attachments))
            }
        } catch (error: RemoteException) {
            // The acknowledgement can be lost after the worker took the message; the transcript then shows it.
            val delivered = session(id)?.messages?.any { message -> message.blocks.orEmpty().any { it.type == "user" && it.id == queued.id && it.cancelled != true } } == true
            if (delivered) return
            // Back where it was, including a hold it was under.
            update(id) { it.copy(queue = listOf(queued) + it.queue, queuePaused = it.queuePaused || !error.confirmed, queueHeld = it.queueHeld || session.queueHeld) }
            throw error
        }
    }

    /** What the message reads as: one that is only files still needs words for Claude. */
    private fun said(text: String, attachments: List<Attachment>): String {
        val value = text.trim()
        if ((value.isEmpty() && attachments.isEmpty()) || text.length > MAX_LENGTH) throw RemoteException("消息不能为空或超过 20 万字符")
        return value.ifEmpty { ATTACHMENTS_ONLY }
    }

    fun send(id: String, text: String, attachments: List<Attachment> = emptyList()) {
        val session = require(id)
        if (session.remoteTask != null) throw RemoteException("Claude 正在回复，请先停止或等待完成")
        val value = said(text, attachments)
        hostOf(session)
        val reply = ChatMessage(id = newId(), role = "assistant", blocks = emptyList(), createdAt = now().toDouble())
        val owner = session.remoteOwner
        update(id) {
            it.copy(
                name = if (it.messages.isEmpty() && it.name == ChatSession.NEW_NAME) value.take(28) else it.name,
                messages = it.messages + ChatMessage(id = newId(), role = "user", text = value, createdAt = now().toDouble(), attachments = attachments.ifEmpty { null }) + reply,
                status = "connecting", updatedAt = now(), queuePaused = false, transportError = null,
                // Stored before anything is sent: after an unanswered request the same task ID is used again.
                remoteTask = RemoteTask(id = owner?.id ?: newId(), prompt = prompt(value, attachments), messageId = reply.id, continuation = owner != null),
            )
        }
        dispatch { if (owner != null) continueTurn(id) else attach(id) }
    }

    /**
     * Contacts the server once the latest change is on disk. A new task ID is always written
     * first, so a reply started just before the app is killed can still be found afterwards.
     */
    private fun dispatch(contact: suspend () -> Unit) {
        val saved = written
        scope.launch {
            saved?.join()
            contact()
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
        val taskId = session.remoteTask?.id ?: session.remoteOwner!!.id
        ensureInstalled(host)
        // Installing can take a while; a reply stopped in the meantime must not be started.
        if (ownerId(id) != taskId || watchers[id] != null) return
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
                dispatch { attach(id) }
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
        val turnEnded = done || status in ENDED
        // A worker that died says so in its last state, but not for the command it was running.
        if (turnEnded) message = if (done && status == "stopped") message.cutShort() else message.settled()
        // Until the worker confirms the stop, states it wrote before hearing of it still say "working".
        if (!turnEnded && id in stopRequests && status != "stopping") status = "stopping"
        if (session.hostId !in catalogue.value) offered(session.hostId, remote["capabilities"])
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
            // A prompt must not count as delivered before the worker has taken it.
            put("wait", session.remoteOwner != null || kind == "send" || kind == "steer")
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

    /**
     * The server entry now points at another machine or account. What ran on the old one
     * stays there: nothing unfinished is sent to the new one, and it is set up from scratch.
     * Messages still waiting in the queue were written for the old machine: they are kept,
     * but held until the user sends them on, whatever else is sent in the meantime.
     */
    fun endpointChanged(host: String) {
        installs.remove(host)
        // What the old machine offered says nothing about the new one.
        catalogue.value = catalogue.value - host
        for (session in state.value.filter { it.hostId == host }) {
            watchers.remove(session.id)?.kill()
            val reply = session.remoteTask?.messageId
            update(session.id) {
                it.copy(
                    messages = it.messages.map { message -> if (message.id == reply) message.cutShort() else message },
                    status = if (it.isBusy) "stopped" else it.status, permissions = emptyList(), transportError = null,
                    remoteTask = null, remoteOwner = null, remoteSessionId = null,
                    // Claude's transcript is on the old machine too.
                    historyRef = null, historyBefore = null, historyTail = null, historyLoose = emptyList(),
                    queueHeld = it.queue.isNotEmpty(),
                )
            }
        }
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
                        messages = it.messages.map { local -> if (local.id == task.messageId) local.cutShort() else local },
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
        val mode = suggestedMode(session.permissions.first { it.id == permission }.suggestions).takeIf { answer["useSuggestedPermissions"].truthy }
        command(session, "respond") { put("permissionId", permission); put("answer", answer) }
        // The server has changed the mode with the rules it saved; the conversation's own setting follows.
        if (mode != null) update(id) { it.copy(preferences = it.preferences.copy(permissionMode = mode.takeIf { name -> name != "default" })) }
    }

    private companion object {
        const val MAX_LENGTH = 200_000
        val ACTIVE = setOf("working", "connecting", "permission", "stopping", "detached")
        val ENDED = setOf("idle", "stopped", "error")
    }
}
