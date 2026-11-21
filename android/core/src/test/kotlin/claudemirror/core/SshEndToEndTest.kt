package claudemirror.core

import java.io.File
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The engine over real SSH against a prepared server: sshd, Node.js, Claude Code and an
 * Anthropic API the test controls. Skipped unless CLAUDE_MIRROR_E2E_HOST is set.
 *
 *   CLAUDE_MIRROR_E2E_HOST / _PORT / _USER / _KEY (private key file) / _PROJECT (directory on the server)
 *   CLAUDE_MIRROR_E2E_PREPARE  optional local command run once the server program is installed
 *
 * The API is expected to answer like test/support/mock-anthropic.cts: SLOWTOOL runs a
 * two second shell command, anything else is answered with "SAW" and the keywords seen.
 */
class SshEndToEndTest {
    private val env = System.getenv()
    private fun text(session: ChatSession) = session.messages.filter { it.role == "assistant" }.joinToString("\n") { m -> m.blocks.orEmpty().joinToString(" ") { it.text.orEmpty() } }

    @Test fun `a conversation over SSH with approval, an inserted message, a follow-up and a stop`() {
        assumeTrue("no test server configured", env["CLAUDE_MIRROR_E2E_HOST"] != null)
        val server = File(System.getProperty("claudemirror.server"))
        val resources = ServerResources.read { server.resolve(it).inputStream() }
        val key = File(env.getValue("CLAUDE_MIRROR_E2E_KEY")).readText()
        var host = HostConfig(
            id = "e2e", user = env.getValue("CLAUDE_MIRROR_E2E_USER"), host = env.getValue("CLAUDE_MIRROR_E2E_HOST"),
            port = env["CLAUDE_MIRROR_E2E_PORT"]?.toInt() ?: 22, directory = env.getValue("CLAUDE_MIRROR_E2E_PROJECT"), auth = AuthMethod.Key,
        )
        val pool = AgentPool(SshLauncher { SshSecret(privateKey = key) }, resources)
        val executor = Executors.newSingleThreadExecutor()
        try {
            runBlocking(executor.asCoroutineDispatcher()) {
                // A server never seen before is not trusted until its fingerprint is accepted.
                val unknown = runCatching { pool.channel(host) }.exceptionOrNull()
                assertTrue("expected the host key question, got $unknown", unknown is UnknownHostKeyException)
                val fingerprint = (unknown as UnknownHostKeyException).fingerprint
                assertTrue(fingerprint.startsWith("SHA256:"))
                val changed = runCatching { pool.channel(host.copy(hostKey = "SHA256:someone-else")) }.exceptionOrNull()
                assertTrue("expected a refusal, got $changed", changed is HostKeyChangedException)
                host = host.copy(hostKey = fingerprint)

                val info = pool.channel(host).info!!
                assertNotNull("Claude Code was not found on the server", info.claude)
                pool.call(host, "task", buildJsonObject { put("operation", "install"); put("digest", resources.bundleDigest); put("payload", resources.bundlePayload) }, timeoutMs = 180_000)
                env["CLAUDE_MIRROR_E2E_PREPARE"]?.let { assertEquals(0, ProcessBuilder("sh", "-c", it).inheritIO().start().waitFor()) }

                val scope = CoroutineScope(coroutineContext + SupervisorJob())
                val engine = Engine(scope, pool, MemoryStore(), host = { host })
                suspend fun until(what: String, seconds: Int = 60, condition: (ChatSession) -> Boolean): ChatSession {
                    repeat(seconds * 20) {
                        val current = engine.sessions.value.first()
                        if (condition(current)) return current
                        delay(50)
                    }
                    error("timed out waiting for: $what\n" + engine.sessions.value.first())
                }
                val id = engine.create(host).id

                // Default permissions: Claude asks before commands that change something.
                engine.send(id, "FIRST SLOWTOOL")
                val begun = until("a permission request or the command") { s -> s.permissions.isNotEmpty() || s.messages.last().blocks.orEmpty().any { it.type == "tool" && it.status == "running" } }
                if (begun.permissions.isNotEmpty()) {
                    assertEquals("permission", begun.status)
                    assertEquals("Bash", begun.permissions.single().name)
                    engine.respond(id, begun.permissions.single().id, buildJsonObject { put("allow", true); put("useSuggestedPermissions", false) })
                    until("the command to run") { s -> s.permissions.isEmpty() && s.messages.last().blocks.orEmpty().any { it.type == "tool" } }
                }
                println("E2E permission asked: " + begun.permissions.isNotEmpty())

                // A message during the reply: read at the next step by a server that supports it, otherwise sent right after.
                engine.submit(id, "STEER", steer = true)
                val first = until("the first reply and the inserted message") { it.status == "idle" && it.remoteTask == null && it.queue.isEmpty() && "STEER" in text(it) }
                assertTrue(text(first), "SAW FIRST" in text(first))
                assertTrue(first.messages.last().blocks.orEmpty().any { it.type == "tool" && it.output.orEmpty().contains("slept") } || first.messages.size > 2)
                // The context size follows the end of the turn on servers that report it.
                repeat(60) { if (engine.sessions.value.first().context == null) delay(50) }
                println("E2E inserted into the running reply: " + (first.messages.size == 2) + ", context: " + engine.sessions.value.first().context?.label)

                // The next prompt goes to the same Claude session.
                val before = first.messages.size
                engine.send(id, "SECOND")
                val second = until("the second reply") { it.status == "idle" && it.remoteTask == null && it.messages.size == before + 2 && "SECOND" in text(it) }
                assertEquals(first.remoteSessionId, second.remoteSessionId)
                assertTrue(text(second), text(second).lines().last().contains("FIRST"))

                // Stop during a command.
                engine.configure(id, Preferences(permissionMode = "bypassPermissions"))
                engine.send(id, "SLOWTOOL SLOWTOOL SLOWTOOL SLOWTOOL")
                until("a command to run") { s -> s.messages.last().blocks.orEmpty().any { it.type == "tool" } }
                engine.submit(id, "never sent")
                engine.stop(id)
                val stopped = until("the stop") { !it.isBusy }
                assertEquals("stopped", stopped.status)
                assertTrue(stopped.messages.last().interrupted == true)
                assertEquals(listOf("never sent"), stopped.queue.map { it.text })
                assertTrue(stopped.queuePaused)
                pool.close(host)
            }
        } finally { executor.shutdownNow() }
    }
}
