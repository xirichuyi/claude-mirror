package claudemirror.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import claudemirror.core.AgentPool
import claudemirror.core.ChatSession
import claudemirror.core.ConnectionState
import claudemirror.core.Engine
import claudemirror.core.FileSessionStore
import claudemirror.core.HostConfig
import claudemirror.core.Preferences
import claudemirror.core.ServerResources
import claudemirror.core.SshLauncher
import claudemirror.core.SshSecret
import claudemirror.core.UnknownHostKeyException
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/** A server seen for the first time, waiting for the user to accept its key. */
data class TrustRequest(val host: HostConfig, val fingerprint: String)

class AppModel(application: Application) : AndroidViewModel(application) {
    private val files = application.filesDir
    private val hostStore = HostStore(File(files, "hosts.json"))
    private val secrets = SecretStore(File(files, "secrets"))
    private val pool = AgentPool(
        SshLauncher { host -> secrets.read(host.id).let { SshSecret(it.password, it.privateKey, it.passphrase) } },
        ServerResources.read { application.assets.open("server/$it") },
    )
    private val _hosts = MutableStateFlow(hostStore.load())
    private val engine = Engine(viewModelScope, pool, FileSessionStore(File(files, "sessions")), host = ::host)

    val hosts: StateFlow<List<HostConfig>> = _hosts
    val sessions: StateFlow<List<ChatSession>> = engine.sessions
    val connections: StateFlow<Map<String, ConnectionState>> = pool.states
    val trust = MutableStateFlow<TrustRequest?>(null)
    /** Short messages for the snackbar. */
    val notices = MutableSharedFlow<String>(extraBufferCapacity = 8)

    private var foreground = false

    init {
        engine.onError = { notices.tryEmit(it) }
        // A connection that drops while the app is open is opened again once, so a reply
        // in progress keeps showing. A failed attempt is left for the user to retry.
        viewModelScope.launch {
            var previous = emptyMap<String, ConnectionState>()
            connections.collect { current ->
                for ((id, state) in current) {
                    if (state !is ConnectionState.Disconnected || previous[id] !is ConnectionState.Connected) continue
                    launch {
                        delay(2000)
                        val host = host(id)
                        if (host != null && foreground && connections.value[id] is ConnectionState.Disconnected && unfinished(id)) connect(host)
                    }
                }
                previous = current
            }
        }
    }

    private fun unfinished(host: String) = sessions.value.any { it.hostId == host && (it.remoteTask != null || it.remoteOwner != null) }

    fun host(id: String): HostConfig? = _hosts.value.firstOrNull { it.id == id }
    fun secret(id: String): HostSecret = secrets.read(id)
    fun newHostId(): String = UUID.randomUUID().toString()

    /** Runs an action the user asked for and reports why it failed. */
    private fun act(block: suspend () -> Unit) {
        viewModelScope.launch {
            try { block() } catch (error: CancellationException) { throw error } catch (error: Exception) {
                notices.tryEmit(error.message ?: "操作失败")
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
            if (previous.host != host.host || previous.port != host.port || previous.user != host.user) engine.endpointChanged(host.id)
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

    /** Opens the SSH connection and rejoins replies that kept running on the server. */
    fun connect(host: HostConfig) {
        viewModelScope.launch {
            try {
                pool.channel(host)
                engine.restore(host)
            } catch (error: CancellationException) { throw error } catch (error: UnknownHostKeyException) {
                trust.value = TrustRequest(host, error.fingerprint)
            } catch (error: Exception) { /* Shown from the connection state. */ }
        }
    }

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
        for (host in _hosts.value) {
            val state = connections.value[host.id]
            if (unfinished(host.id) && state !is ConnectionState.Connected && state !is ConnectionState.Connecting) connect(host)
        }
    }

    fun pause() {
        foreground = false
    }

    fun createSession(host: HostConfig): ChatSession = engine.create(host)
    fun removeSession(id: String) = engine.remove(id)
    fun submit(id: String, text: String, steer: Boolean = false) = runCatching { engine.submit(id, text, steer) }.onFailure { notices.tryEmit(it.message ?: "发送失败") }.isSuccess
    fun steer(id: String, item: String) = act { engine.steer(id, item) }
    fun cancelQueued(id: String, item: String) = engine.cancelQueued(id, item)
    fun clearQueue(id: String) = engine.clearQueue(id)
    fun resumeQueue(id: String) = engine.resumeQueue(id)
    fun stop(id: String) = act { engine.stop(id) }
    fun respond(id: String, permission: String, answer: JsonObject) = act { engine.respond(id, permission, answer) }
    fun configure(id: String, preferences: Preferences) = act { engine.configure(id, preferences) }
    val models = engine.models
    fun loadModels(id: String) = act { engine.loadModels(id) }
}
