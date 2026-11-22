package claudemirror.core

import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

fun json(text: String): JsonObject = MirrorJson.parseToJsonElement(text).jsonObject

/** Runs the server's commands on this machine with a home directory of its own. */
class LocalLauncher(private val home: File) : Launcher {
    override fun start(host: HostConfig, command: String): RemoteProcess {
        val process = ProcessBuilder("sh", "-c", command).apply { environment()["HOME"] = home.path }.start()
        return object : RemoteProcess {
            override val stdout: InputStream = process.inputStream
            override val stdin: OutputStream = process.outputStream
            override fun errorText(): String = if (process.isAlive) "" else process.errorStream.bufferedReader().readText()
            override fun waitForExit(): Int = process.waitFor()
            override fun kill() { process.destroy() }
        }
    }
}

/** An agent that answers from a script, so the engine can be driven through any sequence of worker states. */
class FakeAgent : Launcher {
    class Call(val operation: String, val params: JsonObject)

    val calls = CopyOnWriteArrayList<Call>()
    /** Answers a task command; the default accepts it. */
    @Volatile var onCommand: (JsonObject) -> JsonObject = { json("""{"ok":true}""") }
    @Volatile var status: JsonObject = json("""{"done":false}""")
    @Volatile var inspection: JsonObject = json("{}")
    @Volatile var listing: JsonObject = json("{}")
    /** Answers a request about the conversations Claude Code keeps on the server. */
    @Volatile var onHistory: (JsonObject) -> JsonObject = { json("{}") }
    @Volatile var launches = 0
    @Volatile var installedDelay = 0L
    private val subscriptions = HashMap<String, String>()
    private var output: OutputStream? = null
    private var input: PipedOutputStream? = null

    fun commands(kind: String): List<JsonObject> =
        calls.filter { it.operation == "command" && it.params["command"]!!.jsonObject["kind"].string() == kind }.map { it.params }

    fun starts(): List<JsonObject> = calls.filter { it.operation == "start" }.map { it.params }

    override fun start(host: HostConfig, command: String): RemoteProcess {
        launches += 1
        val requests = PipedInputStream(1 shl 16)
        val requestSink = PipedOutputStream(requests)
        val responses = PipedInputStream(1 shl 16)
        val responseSink = PipedOutputStream(responses)
        synchronized(this) { output = responseSink; input = requestSink; subscriptions.clear() }
        send(json("""{"rcc":"ready"}"""))
        thread(isDaemon = true) {
            runCatching { requests.bufferedReader().forEachLine { answer(json(it)) } }
        }
        return object : RemoteProcess {
            override val stdout: InputStream = responses
            override val stdin: OutputStream = requestSink
            override fun errorText() = ""
            override fun waitForExit() = 0
            override fun kill() { runCatching { responseSink.close() } }
        }
    }

    private fun send(value: JsonObject) = synchronized(this) {
        output?.let { it.write((value.toString() + "\n").toByteArray()); it.flush() }
    }

    private fun answer(request: JsonObject) {
        val id = request["id"] ?: return
        val params = request["params"]!!.jsonObject
        val result: JsonElement = when (request["op"].string()) {
            "file" -> if (params["operation"].string() == "list") listing else json("""{"home":"/home/dev","hostname":"box","node":"v22.1.0","nodeSupported":true}""")
            "history" -> { calls += Call("history:" + params["operation"].string(), params); onHistory(params) }
            "taskWatch" -> {
                synchronized(this) { subscriptions[params["taskId"].string()!!] = params["subscription"].string()!! }
                return
            }
            else -> {
                val operation = params["operation"].string()!!
                calls += Call(operation, params)
                when (operation) {
                    "installed" -> {
                        // Answered late without holding up later requests, like a slow first-time setup.
                        val delay = installedDelay
                        if (delay > 0) {
                            thread(isDaemon = true) { Thread.sleep(delay); send(buildJsonObject { put("id", id); put("result", json("""{"installed":true}""")) }) }
                            return
                        }
                        json("""{"installed":true}""")
                    }
                    "status" -> status
                    "inspect" -> inspection
                    "command" -> onCommand(params)
                    else -> json("{}")
                }
            }
        }
        send(buildJsonObject { put("id", id); put("result", result) })
    }

    /** A state the worker of [taskId] reports to whoever follows it. */
    fun emit(taskId: String, packet: String) {
        val subscription = synchronized(this) { subscriptions[taskId] } ?: error("nobody follows $taskId")
        send(buildJsonObject { put("sub", subscription); put("packet", json(packet)) })
    }

    fun follows(taskId: String): Boolean = synchronized(this) { taskId in subscriptions }

    /** The SSH connection drops. */
    fun disconnect() = synchronized(this) { runCatching { output?.close() }; output = null }
}

open class MemoryStore(private val initial: List<ChatSession> = emptyList()) : SessionStore {
    val saved = java.util.concurrent.ConcurrentHashMap<String, ChatSession>()
    override fun load() = initial
    override fun save(session: ChatSession) { saved[session.id] = session }
    override fun delete(id: String) { saved.remove(id) }
}

val testHost = HostConfig(id = "h1", user = "dev", host = "example.test", directory = "/srv/app")
val testResources = ServerResources("agent".toByteArray(), "agent-digest", "bundle-digest", "payload")

/** Runs [body] on the single thread the engine lives on. */
fun engineTest(agent: Launcher = FakeAgent(), store: SessionStore = MemoryStore(), resources: ServerResources = testResources, body: suspend Fixture.() -> Unit) {
    val executor = Executors.newSingleThreadExecutor()
    try {
        runBlocking(executor.asCoroutineDispatcher()) {
            val scope = CoroutineScope(coroutineContext + kotlinx.coroutines.SupervisorJob())
            val pool = AgentPool(agent, resources)
            val engine = Engine(scope, pool, store, host = { if (it == testHost.id) testHost else null })
            try { withTimeout(60_000) { Fixture(engine, pool, agent as? FakeAgent ?: FakeAgent(), scope).body() } }
            finally { pool.close(testHost); scope.coroutineContext[kotlinx.coroutines.Job]!!.cancel() }
        }
    } finally { executor.shutdownNow() }
}

class Fixture(val engine: Engine, val pool: AgentPool, val agent: FakeAgent, val scope: CoroutineScope) {
    suspend fun until(what: String, condition: () -> Boolean) {
        repeat(500) { if (condition()) return; delay(10) }
        error("timed out waiting for: $what")
    }

    fun current(id: String): ChatSession = engine.session(id)!!

    /** Sends a first prompt and waits until the engine follows the worker. Returns the session and its task. */
    suspend fun started(prompt: String = "first"): Pair<ChatSession, RemoteTask> {
        val session = engine.create(testHost)
        engine.send(session.id, prompt)
        val task = current(session.id).remoteTask!!
        until("the worker is followed") { agent.follows(task.id) }
        return current(session.id) to task
    }

    fun state(task: RemoteTask, version: Int, status: String, text: String = "", extra: String = ""): String =
        """{"version":$version,"status":"$status","permissions":[],"message":{"id":"${task.messageId}","role":"assistant","blocks":[{"type":"text","text":"$text"}]}$extra}"""
}
