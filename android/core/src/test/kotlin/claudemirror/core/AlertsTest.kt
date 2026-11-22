package claudemirror.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AlertsTest {
    private val task = RemoteTask(id = "t1", messageId = "a1")
    private fun reply(text: String, error: String? = null) =
        ChatMessage(id = "a1", role = "assistant", blocks = listOf(Block(type = "tool", name = "Bash"), Block(type = "text", text = text)), error = error)
    private fun session(status: String, running: Boolean, text: String = "", error: String? = null) = ChatSession(
        id = "s1", hostId = "h1", directory = "/srv/app", createdAt = 0, updatedAt = 0, status = status,
        messages = listOf(ChatMessage(id = "u1", role = "user", text = "go"), reply(text, error)), remoteTask = task.takeIf { running },
    )

    @Test fun `a reply that ends is told with its last words`() {
        val found = alerts(listOf(session("working", true, "half")), listOf(session("idle", false, " done \n")))
        assertEquals(listOf<Alert>(Alert.Finished(session("idle", false, " done \n"), "done")), found)
    }

    @Test fun `a reply that fails is told with its error, without diagnostics`() {
        val found = alerts(listOf(session("working", true)), listOf(session("error", false, error = "[ede_diagnostic] x\nAPI Error: 529")))
        assertEquals("API Error: 529", (found.single() as Alert.Failed).reason)
    }

    @Test fun `a reply the user stopped, or one the queue follows, is not news`() {
        assertTrue(alerts(listOf(session("stopping", true)), listOf(session("stopped", false))).isEmpty())
        val queued = session("idle", false).copy(queue = listOf(QueuedMessage("q1", "next")))
        assertTrue(alerts(listOf(session("working", true)), listOf(queued)).isEmpty())
        // A queue that waits for the user does not follow by itself.
        assertEquals(1, alerts(listOf(session("working", true)), listOf(queued.copy(queuePaused = true))).size)
        assertEquals(1, alerts(listOf(session("working", true)), listOf(queued.copy(queueHeld = true))).size)
    }

    @Test fun `a request is told once`() {
        val asking = session("permission", true).copy(permissions = listOf(PermissionRequest(id = "p1", name = "Bash")))
        assertEquals(listOf<Alert>(Alert.Asked(asking, asking.permissions.single())), alerts(listOf(session("working", true)), listOf(asking)))
        assertTrue(alerts(listOf(asking), listOf(asking.copy(updatedAt = 5))).isEmpty())
    }

    @Test fun `nothing is told about a conversation that only just appeared, or did not change`() {
        val idle = session("idle", false)
        assertTrue(alerts(emptyList(), listOf(idle)).isEmpty())
        assertTrue(alerts(listOf(idle), listOf(idle)).isEmpty())
    }
}
