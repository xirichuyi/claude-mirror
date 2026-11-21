package claudemirror.core

import java.net.ServerSocket
import kotlin.concurrent.thread
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SshLauncherTest {
    /** Accepts connections and then says nothing, like a server that is slow to answer. */
    private fun silentServer(): ServerSocket = ServerSocket(0).also { server ->
        thread(isDaemon = true) { runCatching { while (true) server.accept() } }
    }

    private fun host(server: ServerSocket) = HostConfig(id = "slow", user = "dev", host = "127.0.0.1", port = server.localPort, directory = "/srv/app")

    @Test fun `disconnecting does not wait for a connection that is still being set up`() {
        val server = silentServer()
        try {
            val launcher = SshLauncher(handshakeTimeoutMs = 5_000) { SshSecret(password = "x") }
            val connecting = thread(isDaemon = true) { runCatching { launcher.start(host(server), "true") } }
            Thread.sleep(500)
            assertTrue("the attempt should still be in progress", connecting.isAlive)
            val disconnecting = thread(isDaemon = true) { launcher.disconnect(host(server)) }
            disconnecting.join(1000)
            assertFalse("disconnect is still waiting", disconnecting.isAlive)
        } finally { server.close() }
    }

    @Test fun `a server that never answers is given up on`() {
        val server = silentServer()
        try {
            val launcher = SshLauncher(handshakeTimeoutMs = 500) { SshSecret(password = "x") }
            var failure: Throwable? = null
            val connecting = thread(isDaemon = true) { failure = runCatching { launcher.start(host(server), "true") }.exceptionOrNull() }
            connecting.join(10_000)
            assertFalse("still waiting for the silent server", connecting.isAlive)
            assertTrue("$failure", failure is RemoteException && failure?.message.orEmpty().startsWith("无法连接"))
        } finally { server.close() }
    }
}
