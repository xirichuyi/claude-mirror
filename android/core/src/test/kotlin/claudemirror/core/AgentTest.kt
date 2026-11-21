package claudemirror.core

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Runs the real server program on this machine: the same shell commands and JSON lines as over SSH. */
class AgentTest {
    private val server = System.getProperty("claudemirror.server")?.let(::File)

    @Test fun `a fresh server gets the agent uploaded once and answers`() = runBlocking {
        assumeTrue("needs the built server program and Node.js", server?.resolve("manifest.json")?.exists() == true)
        val home = Files.createTempDirectory("mirror-android").toFile()
        try {
            val resources = ServerResources.read { name -> server!!.resolve(name).inputStream() }
            val launches = ArrayList<String>()
            val local = LocalLauncher(home)
            val pool = AgentPool(object : Launcher {
                override fun start(host: HostConfig, command: String): RemoteProcess { launches += command; return local.start(host, command) }
            }, resources)

            val channel = pool.channel(testHost)
            assertTrue(channel.info!!.nodeSupported)
            assertEquals(home.path, channel.info!!.home)
            assertTrue(pool.states.value[testHost.id] is ConnectionState.Connected)
            // Start, upload, start again.
            assertEquals(3, launches.size)
            assertTrue(home.resolve(".local/share/remotecc/agent/${resources.agentDigest}/remote-agent.cjs").length() == resources.agentSource.size.toLong())

            val installed = buildJsonObject { put("operation", "installed"); put("digest", resources.bundleDigest) }
            assertTrue(!pool.call(testHost, "task", installed).obj()!!["installed"].truthy)
            pool.call(testHost, "task", buildJsonObject { put("operation", "install"); put("digest", resources.bundleDigest); put("payload", resources.bundlePayload) }, timeoutMs = 180_000)
            assertTrue(pool.call(testHost, "task", installed).obj()!!["installed"].truthy)

            pool.close(testHost)
            assertTrue(pool.states.value[testHost.id] is ConnectionState.Disconnected)
            pool.channel(testHost)
            assertEquals("the agent is already there the second time", 4, launches.size)
            pool.close(testHost)
        } finally { home.deleteRecursively() }
    }
}
