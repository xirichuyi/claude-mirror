package claudemirror.app

import claudemirror.core.ConnectionCode
import claudemirror.core.LoginKey
import claudemirror.core.RemoteException
import claudemirror.core.AuthMethod
import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import claudemirror.core.Attachment
import claudemirror.core.alerts
import claudemirror.core.AgentPool
import claudemirror.core.Alert
import claudemirror.core.ChatSession
import claudemirror.core.ConnectionState
import claudemirror.core.Engine
import claudemirror.core.FileSessionStore
import claudemirror.core.HostConfig
import claudemirror.core.Preferences
import claudemirror.core.RemoteConversation
import claudemirror.core.RemoteListing
import claudemirror.core.RemoteMember
import claudemirror.core.RemoteMembers
import claudemirror.core.ServerResources
import claudemirror.core.SshLauncher
import claudemirror.core.SshSecret
import claudemirror.core.UnknownHostKeyException
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.dropWhile
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject

/** A server seen for the first time, waiting for the user to accept its key. */
data class TrustRequest(val host: HostConfig, val fingerprint: String)

/** A file picked for the next message: on its way to the server, there ([file]), or refused ([error]). */
data class Picked(
    val id: String, val name: String, val source: Uri? = null, val size: Long = 0, val sent: Long = 0,
    val file: Attachment? = null, val error: String? = null,
)

/** Lives as long as the process, so that a reply can be followed while no screen is open. */
class AppModel(private val application: Application) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val files = application.filesDir
    private val hostStore = HostStore(File(files, "hosts.json"))
    private val secrets = SecretStore(File(files, "secrets"))
    private val ssh = SshLauncher { host -> secrets.read(host.id).let { SshSecret(it.password, it.privateKey, it.passphrase) } }
    private val pool = AgentPool(
        ssh,
        ServerResources.read { application.assets.open("server/$it") },
    )
    private val _hosts = MutableStateFlow(hostStore.load())
    private val engine = Engine(scope, pool, FileSessionStore(File(files, "sessions")), host = ::host)

    val hosts: StateFlow<List<HostConfig>> = _hosts
    val sessions: StateFlow<List<ChatSession>> = engine.sessions
    val connections: StateFlow<Map<String, ConnectionState>> = pool.states
    val trust = MutableStateFlow<TrustRequest?>(null)
    /** Short messages for the snackbar. */
    val snackbar = MutableSharedFlow<String>(extraBufferCapacity = 8)

    /** The files picked for each conversation's next message. */
    val picked = MutableStateFlow<Map<String, List<Picked>>>(emptyMap())
    private val uploads = HashMap<String, Job>()

    /** The conversation to show, asked for from a notification. */
    val target = MutableStateFlow<String?>(null)
    /** Diff line comments per [reviewKey], waiting to be sent together. */
    val reviewComments = MutableStateFlow<Map<String, List<claudemirror.core.ReviewComment>>>(emptyMap())
    fun reviewKey(host: String, directory: String) = "$host\n$directory"

    internal val notices = Notices(application)
    private var foreground = false
    /** Whether [KeepAlive] is holding the process. */
    private var kept = false
    /** Servers whose dropped connection is being opened again. */
    private val recovering = MutableStateFlow(emptySet<String>())

    /**
     * Replies being followed: those of servers that are connected or about to be again. While
     * there are any, the app stays connected out of sight.
     */
    val running: StateFlow<List<ChatSession>> = combine(sessions, connections, recovering) { all, states, again ->
        all.filter { it.remoteTask != null && (it.hostId in again || states[it.hostId].let { state -> state is ConnectionState.Connected || state is ConnectionState.Connecting }) }
    }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    init {
        engine.onError = { snackbar.tryEmit(it) }
        // A connection that drops while a reply is followed is opened again, so the reply keeps
        // showing. In sight one attempt is made and a failure is left for the user to retry;
        // out of sight nobody can, so a few are made before giving up and saying so.
        scope.launch {
            var previous = emptyMap<String, ConnectionState>()
            connections.collect { current ->
                for ((id, state) in current) {
                    if (state is ConnectionState.Connected && previous[id] !== state) resend(id)
                    if (state !is ConnectionState.Disconnected || previous[id] !is ConnectionState.Connected || id in recovering.value) continue
                    recovering.value += id
                    launch { try { recover(id) } finally { recovering.value -= id } }
                }
                previous = current
            }
        }
        scope.launch {
            var before = sessions.value
            sessions.collect { now ->
                if (!foreground) alerts(before, now).forEach(notices::tell)
                if (before !== now) notices.settle(now)
                before = now
            }
        }
        scope.launch {
            // Only who is running matters here, not every word of a reply as it arrives.
            running.map { all -> all.map { it.name } }.distinctUntilChanged().collectLatest { names ->
                if (names.isEmpty()) {
                    // The moment between a reply and the queued message that follows it is not the
                    // end: once stopped out of sight, Android does not let the service start again.
                    delay(3_000)
                    if (kept) KeepAlive.stop(application)
                } else if (kept) notices.update(running.value) else KeepAlive.start(application)
            }
        }
    }

    private suspend fun recover(id: String) {
        for (wait in listOf(2_000L, 10_000L, 30_000L)) {
            delay(wait)
            val host = host(id) ?: return
            if (!(foreground || kept) || !unfinished(id)) return
            when (connections.value[id]) {
                is ConnectionState.Connected -> return
                is ConnectionState.Connecting -> continue
                else -> if (open(host) || foreground) return
            }
        }
        if (foreground || connections.value[id] is ConnectionState.Connected) return
        // Given up: the replies go on running on the server and are joined again when the app is opened.
        sessions.value.filter { it.hostId == id && it.remoteTask != null }.forEach { notices.tell(Alert.Failed(it, "连接断开")) }
    }

    internal fun kept(value: Boolean) {
        val was = kept
        kept = value
        if (value) notices.update(running.value)
        // Stopped by Android while replies are still followed: taken up again when that is allowed.
        else if (!(was && running.value.isNotEmpty() && KeepAlive.start(application))) notices.rest()
    }

    /** True the first time only: whether to ask the user to allow notifications. */
    fun askNotifications(): Boolean {
        val settings = application.getSharedPreferences("app", android.content.Context.MODE_PRIVATE)
        if (settings.getBoolean("askedNotifications", false)) return false
        settings.edit().putBoolean("askedNotifications", true).apply()
        return true
    }

    private fun unfinished(host: String) = sessions.value.any { it.hostId == host && (it.remoteTask != null || it.remoteOwner != null) }

    fun host(id: String): HostConfig? = _hosts.value.firstOrNull { it.id == id }
    fun secret(id: String): HostSecret = secrets.read(id)
    fun newHostId(): String = UUID.randomUUID().toString()

    /** Runs an action the user asked for and reports why it failed. */
    private fun act(block: suspend () -> Unit) {
        scope.launch {
            try { block() } catch (error: CancellationException) { throw error } catch (error: Exception) {
                snackbar.tryEmit(error.message ?: "操作失败")
            }
        }
    }

    fun saveHost(host: HostConfig, secret: HostSecret) {
        val previous = host(host.id)
        secrets.write(host.id, secret)
        _hosts.value = if (previous == null) _hosts.value + host else _hosts.value.map { if (it.id == host.id) host else it }
        hostStore.save(_hosts.value)
        if (previous != null) {
            engine.detach(previous)
            pool.close(previous)
            if (previous.host != host.host || previous.port != host.port || previous.user != host.user) {
                engine.endpointChanged(host.id)
                // Files picked for the next message went to the old machine: they are sent to this one, once it is connected.
                for (session in sessions.value.filter { it.hostId == host.id }) for (file in picked.value[session.id].orEmpty()) {
                    uploads.remove(file.id)?.cancel()
                    if (file.source == null) detach(session.id, file.id)
                    else pick(session.id, file.id) { it.copy(file = null, error = null, sent = 0) }
                }
            }
        }
    }

    fun deleteHost(host: HostConfig) {
        engine.detach(host)
        pool.close(host)
        sessions.value.filter { it.hostId == host.id }.forEach { engine.remove(it.id) }
        secrets.delete(host.id)
        _hosts.value = _hosts.value.filter { it.id != host.id }
        hostStore.save(_hosts.value)
    }

    /** Adds the server in a code from its panel, then swaps the code's one-use key for a key made on this phone. */
    fun connectCode(text: String) = act {
        val code = ConnectionCode.parse(text)
        val host = HostConfig(newHostId(), code.name, code.user, code.host, code.port, "~", auth = AuthMethod.Key, hostKey = code.hostKeyFingerprint)
        val own = withContext(Dispatchers.Default) { LoginKey.generate() }
        try {
            secrets.write(host.id, HostSecret(privateKey = code.privateKey))
            if ("__RCC_CLAIMED__" !in pool.script(host, ConnectionCode.claimScript(own.publicKey))) throw RemoteException("__RCC_USED__")
        } catch (error: Exception) {
            pool.close(host)
            secrets.delete(host.id)
            throw if (error is RemoteException && error.message in setOf("服务器拒绝了这个私钥", "__RCC_USED__")) RemoteException("连接码已使用或已过期") else error
        }
        // The server now accepts only this phone's key: keep it even if the first connection with it fails.
        pool.close(host)
        saveHost(host, HostSecret(privateKey = own.privateKey))
        connect(host)
    }

    /** Opens the SSH connection and rejoins replies that kept running on the server. */
    fun connect(host: HostConfig) {
        scope.launch { open(host) }
    }

    private suspend fun open(host: HostConfig): Boolean =
        try {
            pool.channel(host)
            engine.restore(host)
            true
        } catch (error: CancellationException) { throw error } catch (error: UnknownHostKeyException) {
            trust.value = TrustRequest(host, error.fingerprint)
            false
        } catch (error: Exception) { false /* Shown from the connection state. */ }

    fun reconnect(host: HostConfig) {
        engine.detach(host)
        pool.close(host)
        connect(host)
    }

    fun acceptKey(request: TrustRequest) {
        trust.value = null
        val trusted = request.host.copy(hostKey = request.fingerprint)
        _hosts.value = _hosts.value.map { if (it.id == trusted.id) trusted else it }
        hostStore.save(_hosts.value)
        connect(trusted)
    }

    /** Called when the app comes back to the foreground: Android drops idle connections in the background. */
    fun resume() {
        foreground = true
        notices.clear()
        if (!kept && running.value.isNotEmpty()) KeepAlive.start(application)
        for (host in _hosts.value) {
            val state = connections.value[host.id]
            if (unfinished(host.id) && state !is ConnectionState.Connected && state !is ConnectionState.Connecting) connect(host)
        }
    }

    fun pause() {
        foreground = false
    }

    fun createSession(host: HostConfig, directory: String = host.directory): ChatSession = engine.create(host, directory)
    fun rename(id: String, name: String) = engine.rename(id, name)
    suspend fun folders(host: HostConfig, path: String): RemoteListing = engine.folders(host, path)
    suspend fun history(host: HostConfig): List<RemoteConversation> = engine.history(host)
    suspend fun entries(host: HostConfig, path: String): RemoteListing = engine.entries(host, path)
    suspend fun preview(host: HostConfig, path: String) = engine.preview(host, path)
    suspend fun gitStatus(host: HostConfig, directory: String) = engine.gitStatus(host, directory)
    suspend fun gitDiff(host: HostConfig, path: String) = engine.gitDiff(host, path)
    suspend fun terminal(host: HostConfig, directory: String, columns: Int, rows: Int) =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { ssh.terminal(host, directory, columns, rows) }
    suspend fun adopt(host: HostConfig, item: RemoteConversation): ChatSession = engine.adopt(host, item)
    fun loadEarlier(id: String) = act { engine.loadEarlier(id) }
    /** Quietly: an adopted conversation that cannot be refreshed still shows what it had. */
    fun refresh(id: String) { scope.launch { runCatching { engine.refresh(id) } } }

    fun addProject(host: HostConfig, directory: String) {
        if (directory == host.directory || directory in host.projects) return
        saveProjects(host.id) { it + directory }
    }

    fun removeProject(host: HostConfig, directory: String) = saveProjects(host.id) { it - directory }

    private fun saveProjects(id: String, change: (List<String>) -> List<String>) {
        _hosts.value = _hosts.value.map { if (it.id == id) it.copy(projects = change(it.projects)) else it }
        hostStore.save(_hosts.value)
    }
    suspend fun listMembers(host: HostConfig): List<RemoteMember> = RemoteMembers.parse(pool.members(host, "--list-users"))
    suspend fun addMember(host: HostConfig, name: String, key: String) { pool.members(host, "--add-user", name, "--key", key) }
    suspend fun removeMember(host: HostConfig, name: String) { pool.members(host, "--remove-user", name) }
    fun removeSession(id: String) {
        picked.value[id].orEmpty().forEach { uploads.remove(it.id)?.cancel() }
        picked.update { it - id }
        engine.remove(id)
    }

    /** Sends the text with the files picked for it; nothing goes while one of them is not on the server. */
    fun submit(id: String, text: String, steer: Boolean = false): Boolean {
        val files = picked.value[id].orEmpty()
        if (files.any { it.file == null }) return false
        return runCatching { engine.submit(id, text, files.map { it.file!! }, steer) }
            .onSuccess { picked.update { it - id } }
            .onFailure { snackbar.tryEmit(it.message ?: "发送失败") }.isSuccess
    }

    /** Sends every diff comment as one message to the latest conversation in [directory], or a new one, and opens it. */
    fun sendReview(host: HostConfig, directory: String) {
        val key = reviewKey(host.id, directory)
        val comments = reviewComments.value[key].orEmpty()
        if (comments.isEmpty()) return
        val session = sessions.value.filter { it.hostId == host.id && it.directory == directory }.maxByOrNull { it.updatedAt } ?: createSession(host, directory)
        runCatching { engine.submit(session.id, claudemirror.core.ReviewComment.prompt(comments, directory), emptyList(), false) }
            .onSuccess { reviewComments.update { it - key }; target.value = session.id }
            .onFailure { snackbar.tryEmit(it.message ?: "发送失败") }
    }

    private fun pick(id: String, change: (List<Picked>) -> List<Picked>) = picked.update { all ->
        val files = change(all[id].orEmpty())
        if (files.isEmpty()) all - id else all + (id to files)
    }

    private fun pick(id: String, item: String, change: (Picked) -> Picked) = pick(id) { files -> files.map { if (it.id == item) change(it) else it } }

    /** Starts sending the chosen files to the conversation's server. */
    fun attach(id: String, sources: List<Uri>) {
        val room = MAX_FILES - picked.value[id].orEmpty().size
        if (sources.size > room) snackbar.tryEmit("最多 $MAX_FILES 个")
        for (source in sources.take(room.coerceAtLeast(0))) {
            val item = Picked(UUID.randomUUID().toString(), name(source), source)
            pick(id) { it + item }
            upload(id, item)
        }
    }

    /** Files that are on the server already: those of a queued message taken back for editing. False when they do not fit. */
    fun attach(id: String, files: Collection<Attachment>): Boolean {
        val held = picked.value[id].orEmpty()
        val added = files.filter { file -> held.none { it.file == file } }
        if (held.size + added.size > MAX_FILES) return false.also { snackbar.tryEmit("最多 $MAX_FILES 个") }
        pick(id) { all -> all + added.map { Picked(UUID.randomUUID().toString(), it.name, size = it.size, sent = it.size, file = it) } }
        return true
    }

    fun detach(id: String, item: String) {
        uploads.remove(item)?.cancel()
        pick(id) { files -> files.filter { it.id != item } }
    }

    fun retry(id: String, item: String) {
        val file = picked.value[id]?.firstOrNull { it.id == item && it.error != null } ?: return
        pick(id, item) { it.copy(error = null, sent = 0) }
        upload(id, file)
    }

    /** A connection is there (again): the picked files that are neither on the server nor on their way are sent. */
    private fun resend(host: String) {
        for (session in sessions.value.filter { it.hostId == host }) for (file in picked.value[session.id].orEmpty()) {
            if (file.file != null || file.source == null || file.id in uploads) continue
            pick(session.id, file.id) { it.copy(error = null, sent = 0) }
            upload(session.id, file)
        }
    }

    private fun upload(id: String, item: Picked) {
        val source = item.source ?: return
        val host = sessions.value.firstOrNull { it.id == id }?.let { host(it.hostId) } ?: return
        val content = application.contentResolver
        uploads[item.id] = scope.launch {
            val sending = coroutineContext[Job]
            // A transfer only notices a lost connection when SSH itself gives up, half a minute later.
            val watch = scope.launch {
                connections.map { it[host.id] is ConnectionState.Connected }.distinctUntilChanged().dropWhile { !it }.first { !it }
                if (uploads.remove(item.id, sending)) {
                    pick(id, item.id) { it.copy(error = INTERRUPTED) }
                    sending?.cancel()
                }
            }
            try {
                // Read once to know what it is, so that a file the server already has is not sent again.
                val (size, digest) = withContext(Dispatchers.IO) {
                    val hash = MessageDigest.getInstance("SHA-256")
                    var total = 0L
                    (content.openInputStream(source) ?: throw IOException()).use { input ->
                        val chunk = ByteArray(64 * 1024)
                        while (true) {
                            val count = input.read(chunk)
                            if (count < 0) break
                            hash.update(chunk, 0, count)
                            total += count
                        }
                    }
                    total to hash.digest().joinToString("") { "%02x".format(it) }
                }
                pick(id, item.id) { it.copy(size = size) }
                var shown = 0L
                val file = pool.upload(host, item.name, size, digest, { content.openInputStream(source) ?: throw IOException() }) { sent ->
                    // A step of a twentieth is all the ring can show.
                    if (sent - shown >= size / 20) { shown = sent; pick(id, item.id) { it.copy(sent = sent) } }
                }
                pick(id, item.id) { it.copy(sent = size, file = file) }
            } catch (error: CancellationException) { throw error } catch (error: Exception) {
                // Taken back or cut off meanwhile: that has been shown already.
                ensureActive()
                val message = (error.message ?: "").ifBlank { "上传失败" }
                pick(id, item.id) { it.copy(error = message) }
                snackbar.tryEmit(message)
            } finally { watch.cancel(); uploads.remove(item.id, sending) }
        }
    }

    private fun name(source: Uri): String =
        runCatching {
            application.contentResolver.query(source, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull()?.takeIf { it.isNotBlank() } ?: source.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "file"
    fun steer(id: String, item: String) = act { engine.steer(id, item) }
    fun cancelQueued(id: String, item: String) = engine.cancelQueued(id, item)
    fun clearQueue(id: String) = engine.clearQueue(id)
    fun resumeQueue(id: String) = engine.resumeQueue(id)
    fun stop(id: String) = act { engine.stop(id) }
    fun respond(id: String, permission: String, answer: JsonObject) = act { engine.respond(id, permission, answer) }

    /**
     * An answer given from a notification. The connection may have been given up by then, and no
     * screen is there to open it again, so the reply is joined first: its end is still to be told.
     * [settled] is called when the answer has been sent, or after the few seconds Android gives a
     * broadcast; a slow connection is then waited for as long as the process lasts.
     */
    fun answer(id: String, permission: String, answer: JsonObject, settled: () -> Unit) {
        val sending = scope.launch {
            val host = sessions.value.firstOrNull { it.id == id }?.let { host(it.hostId) } ?: return@launch
            if (connections.value[host.id] !is ConnectionState.Connected && !open(host)) return@launch
            try { engine.respond(id, permission, answer) } catch (error: CancellationException) { throw error } catch (_: Exception) {}
        }
        scope.launch {
            withTimeoutOrNull(8_000) { sending.join() }
            settled()
        }
    }
    fun configure(id: String, preferences: Preferences) = act { engine.configure(id, preferences) }
    val models = engine.models
    /** Whether the server's models are known after asking. A failure shows where they were asked for. */
    suspend fun fetchModels(id: String): Boolean =
        try { engine.loadModels(id); true } catch (error: CancellationException) { throw error } catch (error: Exception) { false }

    private companion object { const val MAX_FILES = 10; const val INTERRUPTED = "上传中断" }
}
