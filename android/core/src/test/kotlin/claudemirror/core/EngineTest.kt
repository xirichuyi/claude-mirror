package claudemirror.core

import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineTest {
    @Test fun `a prompt starts one task and its reply streams in`() = engineTest {
        val (session, task) = started("hello")
        val start = agent.starts().single()
        assertEquals(task.id, start["taskId"].string())
        assertEquals("hello", start["request"]!!.jsonObject["prompt"].string())
        val sent = start["request"]!!.jsonObject["session"]!!.jsonObject
        assertEquals("/srv/app", sent["directory"].string())
        assertEquals(task.messageId, sent["messages"]!!.jsonArray.single().jsonObject["id"].string())

        agent.emit(task.id, state(task, 1, "working", "Hel", ""","model":"claude-opus","context":{"usedTokens":128400,"maxTokens":1000000}"""))
        agent.emit(task.id, """{"delta":true,"base":1,"version":2,"patches":[{"path":["version"],"value":2},{"path":["message","blocks",0,"text"],"append":"lo"}]}""")
        until("the reply text arrives") { current(session.id).messages.last().blocks?.firstOrNull()?.text == "Hello" }
        assertEquals("working", current(session.id).status)
        assertEquals("128k / 1M", current(session.id).context?.label)
        assertEquals("hello", current(session.id).name)

        agent.emit(task.id, state(task, 3, "idle", "Hello", ""","done":true,"remoteSessionId":"claude-1""""))
        until("the turn ends") { current(session.id).remoteTask == null }
        assertEquals("idle", current(session.id).status)
        assertEquals("claude-1", current(session.id).remoteSessionId)
        assertNull(current(session.id).remoteOwner)
        until("the finished task is acknowledged") { agent.calls.any { it.operation == "acknowledge" } }
    }

    @Test fun `a message sent during a reply waits, then goes to the worker that stayed alive`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, state(task, 1, "working", "one", ""","resident":true"""))
        until("the worker is known to stay") { current(session.id).remoteOwner != null }
        engine.submit(session.id, "second")
        assertEquals(listOf("second"), current(session.id).queue.map { it.text })
        assertEquals(1, agent.starts().size)

        agent.emit(task.id, state(task, 2, "idle", "one", ""","resident":true"""))
        until("the queued message is sent") { agent.commands("send").isNotEmpty() }
        val send = agent.commands("send").single()
        assertEquals(task.id, send["taskId"].string())
        assertEquals("second", send["command"]!!.jsonObject["prompt"].string())
        assertTrue(current(session.id).queue.isEmpty())
        assertEquals(listOf("user", "assistant", "user", "assistant"), current(session.id).messages.map { it.role })
        assertEquals(1, agent.starts().size)
    }

    @Test fun `a message inserted into the running reply leaves the queue once and is never sent again`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, state(task, 1, "working"))
        until("working") { current(session.id).status == "working" }
        engine.submit(session.id, "look at the tests too", steer = true)
        until("the worker takes it") { agent.commands("steer").isNotEmpty() }
        // The worker's own answer is awaited, also before its first state has arrived.
        assertEquals(JsonPrimitive(true), agent.commands("steer").single()["wait"])
        val steer = agent.commands("steer").single()["command"]!!.jsonObject
        assertEquals("look at the tests too", steer["prompt"].string())
        until("it left the queue") { current(session.id).queue.isEmpty() }

        val id = steer["id"].string()
        agent.emit(task.id, """{"version":2,"status":"idle","permissions":[],"done":true,"message":{"id":"${task.messageId}","role":"assistant","blocks":[{"type":"text","text":"a"},{"type":"user","id":"$id","text":"look at the tests too"}]}}""")
        until("the turn ends") { current(session.id).remoteTask == null }
        assertTrue(agent.commands("send").isEmpty())
        assertEquals(1, agent.starts().size)
        assertEquals("user", current(session.id).messages.last().blocks!!.last().type)
    }

    @Test fun `a worker that cannot take an inserted message leaves it first in the queue`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, state(task, 1, "working"))
        engine.submit(session.id, "later")
        agent.onCommand = { json("""{"ok":false,"error":"未知会话请求"}""") }
        engine.submit(session.id, "now", steer = true)
        until("the refusal comes back") { agent.commands("steer").isNotEmpty() && current(session.id).queue.size == 2 }
        assertEquals(listOf("now", "later"), current(session.id).queue.map { it.text })
        assertFalse(current(session.id).queuePaused)

        // An unanswered request may have been delivered, so the message must not go out again by itself.
        agent.onCommand = { json("""{"ok":false,"error":"超时","uncertain":true}""") }
        runCatching { engine.steer(session.id, current(session.id).queue.first().id) }
        assertEquals(listOf("now", "later"), current(session.id).queue.map { it.text })
        assertTrue(current(session.id).queuePaused)

        // The worker did take it after all: the transcript says so, and the copy in the queue goes away.
        val id = current(session.id).queue.first().id
        agent.emit(task.id, """{"version":2,"status":"working","permissions":[],"message":{"id":"${task.messageId}","role":"assistant","blocks":[{"type":"user","id":"$id","text":"now"}]}}""")
        until("the delivered copy leaves the queue") { current(session.id).queue.map { it.text } == listOf("later") }
    }

    @Test fun `an inserted message whose acknowledgement was lost is not sent twice`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, state(task, 1, "working"))
        until("working") { current(session.id).status == "working" }
        agent.onCommand = { params ->
            val id = params["command"]!!.jsonObject["id"].string()
            agent.emit(task.id, """{"version":2,"status":"working","permissions":[],"message":{"id":"${task.messageId}","role":"assistant","blocks":[{"type":"user","id":"$id","text":"now","pending":true}]}}""")
            Thread.sleep(100)
            json("""{"ok":false,"error":"超时","uncertain":true}""")
        }
        engine.submit(session.id, "now")
        engine.steer(session.id, current(session.id).queue.single().id)
        assertEquals(1, agent.commands("steer").size)
        assertTrue(current(session.id).messages.last().blocks!!.any { it.type == "user" })
        assertTrue(current(session.id).queue.isEmpty())
        assertFalse(current(session.id).queuePaused)
    }

    @Test fun `stop shows at once, survives older states and pauses the queue`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, state(task, 1, "working", "partial"))
        until("working") { current(session.id).status == "working" }
        engine.submit(session.id, "queued")
        agent.onCommand = { params ->
            if (params["command"]!!.jsonObject["kind"].string() == "stop") {
                // A state written before the worker heard of the stop.
                agent.emit(task.id, state(task, 2, "working", "partial more"))
                Thread.sleep(150)
                agent.emit(task.id, state(task, 3, "stopped", "partial more", ""","done":true"""))
            }
            json("""{"ok":true}""")
        }
        val job = scope.launch { runCatching { engine.stop(session.id) } }
        until("stopping is shown") { current(session.id).status == "stopping" }
        until("the older state arrived") { current(session.id).messages.last().blocks?.first()?.text == "partial more" || current(session.id).status == "stopped" }
        assertTrue(current(session.id).status in setOf("stopping", "stopped"))
        job.join()
        until("stopped") { current(session.id).status == "stopped" }
        assertTrue(current(session.id).messages.last().interrupted == true)
        assertTrue(current(session.id).queuePaused)
        assertEquals(listOf("queued"), current(session.id).queue.map { it.text })
        assertTrue(agent.commands("send").isEmpty())
        assertEquals(1, agent.commands("stop").size)
    }

    @Test fun `a permission request is shown and answered`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, """{"version":1,"status":"permission","permissions":[{"id":"p1","kind":"tool","name":"Bash","input":{"command":"rm -rf build"}}],"message":{"id":"${task.messageId}","role":"assistant","blocks":[]}}""")
        until("the request is shown") { current(session.id).permissions.isNotEmpty() }
        assertEquals("permission", current(session.id).status)
        engine.respond(session.id, "p1", json("""{"allow":false,"reason":"not now"}"""))
        val respond = agent.commands("respond").single()["command"]!!.jsonObject
        assertEquals("p1", respond["permissionId"].string())
        assertEquals(json("""{"allow":false,"reason":"not now"}"""), respond["answer"])
        assertTrue(runCatching { engine.respond(session.id, "gone", json("{}")) }.isFailure)
    }

    @Test fun `a dropped connection detaches the reply and reconnecting rejoins the same task`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, state(task, 1, "working", "half"))
        until("working") { current(session.id).status == "working" }
        agent.disconnect()
        until("detached") { current(session.id).status == "detached" }
        assertEquals(task.id, current(session.id).remoteTask?.id)
        assertTrue(current(session.id).queuePaused)

        engine.restore(testHost)
        until("followed again") { agent.follows(task.id) }
        assertEquals(2, agent.launches)
        assertEquals(listOf(task.id, task.id), agent.starts().map { it["taskId"].string() })
        agent.emit(task.id, state(task, 2, "idle", "half done", ""","done":true"""))
        until("the turn ends") { current(session.id).remoteTask == null }
        assertEquals("half done", current(session.id).messages.last().blocks!!.single().text)
        assertEquals(2, current(session.id).messages.size)
    }

    @Test fun `conversations are stored and come back`() {
        val store = MemoryStore()
        var id = ""
        engineTest(store = store) {
            val (session, task) = started("remember me")
            id = session.id
            agent.emit(task.id, state(task, 1, "idle", "done", ""","done":true"""))
            until("saved after the turn") { store.saved[id]?.status == "idle" && store.saved[id]?.messages?.size == 2 }
        }
        val text = MirrorJson.encodeToString(ChatSession.serializer(), store.saved[id]!!)
        assertEquals(store.saved[id], MirrorJson.decodeFromString(ChatSession.serializer(), text))
    }

    @Test fun `a prompt stopped while the server is being prepared is never started`() = engineTest {
        agent.installedDelay = 400
        agent.onCommand = { json("""{"ok":false,"error":"任务不存在"}""") }
        val session = engine.create(testHost)
        engine.send(session.id, "first")
        until("the server is being prepared") { agent.calls.any { it.operation == "installed" } }
        engine.stop(session.id)
        assertEquals("stopped", current(session.id).status)
        assertNull(current(session.id).remoteTask)
        assertTrue(current(session.id).messages.last().interrupted == true)
        delay(800)
        assertTrue(agent.starts().isEmpty())
    }

    @Test fun `the task is on disk before the server hears of the prompt`() {
        val gate = java.util.concurrent.CountDownLatch(1)
        val store = object : MemoryStore() {
            override fun save(session: ChatSession) { gate.await(); super.save(session) }
        }
        engineTest(store = store) {
            val session = engine.create(testHost)
            engine.send(session.id, "first")
            delay(300)
            assertEquals(0, agent.launches)
            gate.countDown()
            until("the prompt is sent") { agent.starts().isNotEmpty() }
            assertEquals(agent.starts().single()["taskId"].string(), store.saved[session.id]?.remoteTask?.id)
        }
    }

    @Test fun `a task restarted after the worker went to sleep is also on disk first`() {
        val gate = java.util.concurrent.CountDownLatch(1)
        var armed = false
        var saves = 0
        val store = object : MemoryStore() {
            // Lets the write of the new prompt through and holds the one with the replacement task.
            override fun save(session: ChatSession) {
                if (armed && ++saves == 2) gate.await()
                super.save(session)
            }
        }
        engineTest(store = store) {
            val (session, task) = started()
            agent.emit(task.id, state(task, 1, "idle", "one", ""","resident":true"""))
            until("the worker stays") { current(session.id).remoteOwner != null && current(session.id).remoteTask == null }
            delay(1200) // lets the throttled write of that state finish
            agent.status = json(state(task, 2, "idle", "one", ""","done":true,"hibernated":true,"remoteSessionId":"claude-1""""))
            armed = true
            engine.send(session.id, "second")
            until("a replacement task is chosen") { current(session.id).remoteTask?.let { it.id != task.id } == true }
            delay(300)
            assertEquals(1, agent.starts().size)
            gate.countDown()
            until("the replacement starts") { agent.starts().size == 2 }
            assertEquals(agent.starts().last()["taskId"].string(), store.saved[session.id]?.remoteTask?.id)
            assertEquals("claude-1", agent.starts().last()["request"]!!.jsonObject["session"]!!.jsonObject["remoteSessionId"].string())
        }
    }

    @Test fun `a conversation that cannot be written is reported and stays usable`() {
        val store = object : MemoryStore() {
            override fun save(session: ChatSession) = throw java.io.IOException("No space left on device")
        }
        engineTest(store = store) {
            var reported = ""
            engine.onError = { reported = it }
            val (session, task) = started()
            until("the failure is reported") { "No space left on device" in reported }
            agent.emit(task.id, state(task, 1, "idle", "still here", ""","done":true"""))
            until("the reply arrives") { current(session.id).messages.last().blocks?.firstOrNull()?.text == "still here" }
        }
    }

    @Test fun `a server entry pointed elsewhere leaves its unfinished replies behind`() = engineTest {
        val (session, task) = started("private prompt")
        agent.emit(task.id, state(task, 1, "working", "half", ""","remoteSessionId":"claude-1""""))
        until("working") { current(session.id).status == "working" }
        engine.submit(session.id, "queued")
        engine.detach(testHost)
        engine.endpointChanged(testHost.id)
        val left = current(session.id)
        assertEquals("stopped", left.status)
        assertNull(left.remoteTask)
        assertNull(left.remoteOwner)
        assertNull(left.remoteSessionId)
        assertTrue(left.messages.last().interrupted == true)
        assertEquals(listOf("queued"), left.queue.map { it.text })
        assertTrue(left.queueHeld)

        // Nothing of the old conversation reaches the new machine by itself, and it is set up again.
        engine.restore(testHost)
        delay(200)
        assertEquals(1, agent.starts().size)
        engine.send(session.id, "new machine")
        until("a new task starts") { agent.starts().size == 2 }
        val next = current(session.id).remoteTask!!
        until("the new worker is followed") { agent.follows(next.id) }
        agent.emit(next.id, state(next, 1, "idle", "hello", ""","done":true"""))
        until("the new reply ends") { current(session.id).remoteTask == null }
        delay(200)
        assertEquals("the old queued message must not follow by itself", 2, agent.starts().size)
        assertTrue(agent.commands("send").isEmpty())
        assertEquals(listOf("queued"), current(session.id).queue.map { it.text })

        // The user's go-ahead sends it.
        engine.resumeQueue(session.id)
        until("the held message is sent") { agent.starts().size == 3 }
        assertEquals("queued", agent.starts().last()["request"]!!.jsonObject["prompt"].string())
        assertFalse(current(session.id).queueHeld)
    }

    @Test fun `a command left behind on the old machine no longer shows as running`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, """{"version":1,"status":"permission","permissions":[],"message":{"id":"${task.messageId}","role":"assistant","blocks":[
            {"type":"tool","id":"t1","name":"Bash","status":"done"},
            {"type":"tool","id":"t2","name":"Task","status":"running","children":[{"id":"c1","name":"Bash","status":"running"}]}]}}""")
        until("the command waits") { current(session.id).status == "permission" }
        engine.detach(testHost)
        engine.endpointChanged(testHost.id)
        val tools = current(session.id).messages.last().blocks!!
        assertEquals(listOf("done", "stopped"), tools.map { it.status })
        assertEquals("stopped", tools[1].children!!.single().status)
    }

    @Test fun `a command whose worker died no longer shows as running`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, """{"version":1,"status":"error","done":true,"permissions":[],"message":{"id":"${task.messageId}","role":"assistant","error":"远端任务进程异常退出（signal）","blocks":[
            {"type":"tool","id":"t1","name":"Bash","status":"running"}]}}""")
        until("the failure arrives") { current(session.id).status == "error" }
        val reply = current(session.id).messages.last()
        assertEquals("stopped", reply.blocks!!.single().status)
        assertNull(reply.interrupted)
    }

    @Test fun `a held message the worker would not take is still held`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, state(task, 1, "working"))
        until("working") { current(session.id).status == "working" }
        engine.submit(session.id, "for the old machine")
        engine.detach(testHost)
        engine.endpointChanged(testHost.id)
        engine.send(session.id, "new machine")
        val next = current(session.id).remoteTask!!
        until("the new worker is followed") { agent.follows(next.id) }

        agent.onCommand = { json("""{"ok":false,"error":"未知会话请求"}""") }
        assertTrue(runCatching { engine.steer(session.id, current(session.id).queue.single().id) }.isFailure)
        assertEquals(listOf("for the old machine"), current(session.id).queue.map { it.text })
        assertTrue(current(session.id).queueHeld)
        agent.emit(next.id, state(next, 1, "idle", "hello", ""","done":true"""))
        until("the reply ends") { current(session.id).remoteTask == null }
        delay(200)
        assertEquals(2, agent.starts().size)
    }

    @Test fun `discarding the held messages ends the hold`() = engineTest {
        val (session, task) = started()
        agent.emit(task.id, state(task, 1, "working"))
        until("working") { current(session.id).status == "working" }
        engine.submit(session.id, "for the old machine")
        engine.detach(testHost)
        engine.endpointChanged(testHost.id)
        assertTrue(current(session.id).queueHeld)
        engine.clearQueue(session.id)
        assertFalse(current(session.id).queueHeld)

        // A message queued on the new machine goes out by itself again.
        engine.send(session.id, "new machine")
        val next = current(session.id).remoteTask!!
        until("the new worker is followed") { agent.follows(next.id) }
        engine.submit(session.id, "follow-up")
        agent.emit(next.id, state(next, 1, "idle", "hello", ""","done":true"""))
        until("the follow-up is sent") { agent.starts().size == 3 }
        assertEquals("follow-up", agent.starts().last()["request"]!!.jsonObject["prompt"].string())
        assertEquals(2, agent.calls.count { it.operation == "installed" })
        assertEquals("new machine", agent.starts()[1]["request"]!!.jsonObject["prompt"].string())
        assertNull(agent.starts()[1]["request"]!!.jsonObject["session"]!!.jsonObject["remoteSessionId"])
    }

    @Test fun `a server entry pointed elsewhere asks the new machine for its models`() = engineTest {
        val session = engine.create(testHost)
        agent.inspection = json("""{"models":[{"value":"opus"}]}""")
        engine.loadModels(session.id)
        assertEquals(listOf("opus"), engine.models.value[testHost.id]?.map { it.value })

        engine.endpointChanged(testHost.id)
        assertNull(engine.models.value[testHost.id])
        agent.inspection = json("""{"models":[{"value":"sonnet"}]}""")
        engine.loadModels(session.id)
        assertEquals(listOf("sonnet"), engine.models.value[testHost.id]?.map { it.value })
    }

    private fun record(id: String, role: String, text: String) =
        """{"type":"$role","uuid":"$id","message":{"content":[{"type":"text","text":"$text"}]}}"""

    @Test fun `a conversation from the server is continued here, not started over`() = engineTest {
        agent.onHistory = { request ->
            when (request["operation"].string()) {
                "list" -> json("""{"sessions":[{"reference":"p/s1.jsonl","sessionId":"s1","directory":"/srv/other","name":"<b>fix</b> it","updatedAt":5000}],"nextOffset":null}""")
                else -> if (request["before"].string() == "m3") json("""{"records":[${record("m1", "user", "first")},${record("m2", "assistant", "one")}],"directory":"/srv/other","before":null}""")
                    else json("""{"records":[${record("m3", "user", "second")},${record("m4", "assistant", "two")}],"directory":"/srv/other","before":"m3"}""")
            }
        }
        val item = engine.history(testHost).single()
        val session = engine.adopt(testHost, item)
        assertEquals("fix it", session.name)
        assertEquals("/srv/other", session.directory)
        assertEquals(listOf("m3", "m4"), session.messages.map { it.id })
        assertEquals(session.id, engine.adopt(testHost, item).id)

        engine.loadEarlier(session.id)
        assertEquals(listOf("m1", "m2", "m3", "m4"), current(session.id).messages.map { it.id })
        assertNull(current(session.id).historyBefore)

        engine.send(session.id, "third")
        until("the reply is started") { agent.starts().isNotEmpty() }
        assertEquals("s1", agent.starts().single()["request"]!!.jsonObject["session"]!!.jsonObject["remoteSessionId"].string())
    }

    @Test fun `what was said elsewhere shows up, and what was said here is not lost to an older transcript`() = engineTest {
        var transcript = listOf(record("m1", "user", "first"), record("m2", "assistant", "one"))
        agent.onHistory = { json("""{"records":[${transcript.joinToString(",")}],"directory":"/srv/app","before":null}""") }
        val session = engine.adopt(testHost, RemoteConversation("p/s1.jsonl", "s1", "/srv/app", "first"))

        transcript = transcript + record("m3", "user", "from the terminal") + record("m4", "assistant", "two")
        engine.refresh(session.id)
        assertEquals(listOf("m1", "m2", "m3", "m4"), current(session.id).messages.map { it.id })

        // A turn from the phone, finished, which Claude has not written to its transcript yet.
        engine.send(session.id, "from the phone")
        val task = current(session.id).remoteTask!!
        until("the worker is followed") { agent.follows(task.id) }
        agent.emit(task.id, state(task, 1, "idle", "three", ""","done":true"""))
        until("the reply ends") { current(session.id).remoteTask == null && current(session.id).remoteOwner == null }
        val shown = current(session.id).messages
        engine.refresh(session.id)
        assertEquals(shown, current(session.id).messages)

        transcript = transcript + record("m5", "user", "from the phone") + record("m6", "assistant", "three") + record("m7", "user", "later, elsewhere")
        engine.refresh(session.id)
        assertEquals(listOf("m1", "m2", "m3", "m4", "m5", "m6", "m7"), current(session.id).messages.map { it.id })
    }

    @Test fun `a new conversation starts in the project it was asked for, and takes a new name`() = engineTest {
        agent.listing = json("""{"path":"/srv","parent":"/","entries":[{"path":"/srv/app","name":"app","directory":true},{"path":"/srv/notes.txt","name":"notes.txt","directory":false}]}""")
        assertEquals(listOf("app"), engine.folders(testHost, "/srv").entries.map { it.name })
        val session = engine.create(testHost, "/srv/app2")
        assertEquals("/srv/app2", session.directory)
        engine.rename(session.id, "  renamed  ")
        engine.rename(session.id, "   ")
        assertEquals("renamed", current(session.id).name)
        engine.send(session.id, "hello")
        assertEquals("renamed", current(session.id).name)
    }

    @Test fun `more than a page said elsewhere replaces what is shown`() = engineTest {
        var reply = """{"records":[${record("m1", "user", "first")},${record("m2", "assistant", "one")}],"directory":"/srv/app","before":null}"""
        agent.onHistory = { json(reply) }
        val session = engine.adopt(testHost, RemoteConversation("p/s1.jsonl", "s1", "/srv/app", "first"))

        reply = """{"records":[${record("n1", "user", "much later")},${record("n2", "assistant", "yes")}],"directory":"/srv/app","before":"n1"}"""
        engine.refresh(session.id)
        assertEquals(listOf("n1", "n2"), current(session.id).messages.map { it.id })
        assertEquals("n1", current(session.id).historyBefore)
    }

    @Test fun `a prompt that never reached Claude neither holds back the transcript nor is lost`() {
        val adopted = ChatSession(
            id = "c1", hostId = testHost.id, directory = "/srv/app", createdAt = 1, updatedAt = 1, remoteSessionId = "s1", historyRef = "p/s1.jsonl", historyTail = "m2",
            messages = listOf(
                ChatMessage(id = "m1", role = "user", text = "first"), ChatMessage(id = "m2", role = "assistant", blocks = listOf(Block(type = "text", text = "one"))),
                ChatMessage(id = "l1", role = "user", text = "lost on the way"), ChatMessage(id = "l2", role = "assistant", blocks = emptyList(), error = "连接中断"),
            ),
        )
        engineTest(store = MemoryStore(listOf(adopted))) {
            agent.onHistory = { json("""{"records":[${record("m1", "user", "first")},${record("m2", "assistant", "one")},${record("m3", "user", "elsewhere")}],"directory":"/srv/app","before":null}""") }
            engine.refresh("c1")
            assertEquals(listOf("m1", "m2", "m3", "l1", "l2"), current("c1").messages.map { it.id })
            engine.refresh("c1")
            assertEquals(listOf("m1", "m2", "m3", "l1", "l2"), current("c1").messages.map { it.id })
        }
    }

    @Test fun `the earlier part gets the results the later part held for its tools`() = engineTest {
        agent.onHistory = { request ->
            if (request["before"].string() == "u2") json("""{"records":[{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}],"directory":"/srv/app","before":null}""")
            else json("""{"records":[{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt"}]}},${record("a2", "assistant", "Done.")}],"directory":"/srv/app","before":"u2"}""")
        }
        val session = engine.adopt(testHost, RemoteConversation("p/s1.jsonl", "s1", "/srv/app", "first"))
        engine.loadEarlier(session.id)
        assertEquals(listOf("a1", "a2"), current(session.id).messages.map { it.id })
        assertEquals("a.txt", current(session.id).messages.first().blocks!!.single().output)
        assertTrue(current(session.id).historyLoose.isEmpty())
    }

    @Test fun `a server entry pointed elsewhere forgets the old machine's transcript`() = engineTest {
        agent.onHistory = { json("""{"records":[${record("m1", "user", "first")}],"directory":"/srv/app","before":null}""") }
        val session = engine.adopt(testHost, RemoteConversation("p/s1.jsonl", "s1", "/srv/app", "first"))
        engine.endpointChanged(testHost.id)
        assertNull(current(session.id).historyRef)
        engine.refresh(session.id)
        assertEquals(1, agent.calls.count { it.operation == "history:messages" })
    }
}
