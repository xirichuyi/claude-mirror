package claudemirror.core

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
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

            // A file is sent once: the second time the server finds it by what it contains.
            val bytes = ByteArray(300_000) { (it * 31).toByte() }
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            var progress = 0L
            val before = launches.size
            val first = pool.upload(testHost, "a/b's \"photo\".png", bytes.size.toLong(), digest, { bytes.inputStream() }) { progress = it }
            try {
                assertEquals("a_b's \"photo\".png", first.name)
                assertTrue(File(first.path).readBytes().contentEquals(bytes))
                assertEquals(bytes.size.toLong(), progress)
                assertEquals(before + 1, launches.size)
                assertEquals(first, pool.upload(testHost, "a/b's \"photo\".png", bytes.size.toLong(), digest, { bytes.inputStream() }))
                assertEquals("nothing is sent the second time", before + 1, launches.size)
                val refused = runCatching { pool.upload(testHost, "other.bin", bytes.size.toLong(), "0".repeat(64), { bytes.inputStream() }) }.exceptionOrNull()
                assertTrue(refused is RemoteException)
            } finally { File(first.path).parentFile!!.deleteRecursively() }

            pool.close(testHost)
            assertTrue(pool.states.value[testHost.id] is ConnectionState.Disconnected)
            val started = launches.size
            pool.channel(testHost)
            assertEquals("the agent is already there the second time", started + 1, launches.size)
            pool.close(testHost)
        } finally { home.deleteRecursively() }
    }
}
