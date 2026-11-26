package claudemirror.core

import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
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
            val killers = CopyOnWriteArrayList<String>()
            val pool = AgentPool(object : Launcher {
                override fun start(host: HostConfig, command: String): RemoteProcess {
                    launches += command
                    val process = local.start(host, command)
                    return object : RemoteProcess by process { override fun kill() { killers += Thread.currentThread().name; process.kill() } }
                }
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
                assertEquals("the bytes go over the agent's own channel", before, launches.size)
                assertEquals(first, pool.upload(testHost, "a/b's \"photo\".png", bytes.size.toLong(), digest, { bytes.inputStream() }))
                val refused = runCatching { pool.upload(testHost, "other.bin", bytes.size.toLong(), "0".repeat(64), { bytes.inputStream() }) }.exceptionOrNull()
                assertTrue(refused is RemoteException)
            } finally { File(first.path).parentFile!!.deleteRecursively() }

            // Taking a file back while it is being sent tells the agent at once; the channel stays up.
            val caller = Executors.newSingleThreadExecutor { Thread(it, "caller") }
            try {
                val reached = CountDownLatch(1)
                val release = CountDownLatch(1)
                val slow = object : InputStream() {
                    private var given = false
                    override fun read(): Int = throw UnsupportedOperationException()
                    override fun read(target: ByteArray, offset: Int, length: Int): Int {
                        if (given) { reached.countDown(); release.await() } else given = true
                        return if (release.count == 0L) -1 else length.also { target.fill(1, offset, offset + length) }
                    }
                }
                killers.clear()
                val sending = launch(caller.asCoroutineDispatcher()) { pool.upload(testHost, "slow.bin", 1_000_000, "1".repeat(64), { slow }) }
                assertTrue(reached.await(30, TimeUnit.SECONDS))
                sending.cancel()
                val attachments = File(System.getProperty("java.io.tmpdir"), "claudock-attachments-" + java.nio.file.Files.getAttribute(home.toPath(), "unix:uid"))
                val deadline = System.currentTimeMillis() + 30_000
                fun leftovers() = attachments.walkTopDown().count { it.name.startsWith(".remotecc-upload") }
                while (leftovers() > 0 && System.currentTimeMillis() < deadline) Thread.sleep(10)
                release.countDown()
                sending.join()
                assertEquals(0, leftovers())
                assertTrue(killers.isEmpty())
                assertTrue(pool.call(testHost, "file", buildJsonObject { put("operation", "hello") }).obj()!!["home"] != null)
            } finally { caller.shutdown() }

            pool.close(testHost)
            assertTrue(pool.states.value[testHost.id] is ConnectionState.Disconnected)
            val started = launches.size
            pool.channel(testHost)
            assertEquals("the agent is already there the second time", started + 1, launches.size)
            pool.close(testHost)
        } finally { home.deleteRecursively() }
    }
}
