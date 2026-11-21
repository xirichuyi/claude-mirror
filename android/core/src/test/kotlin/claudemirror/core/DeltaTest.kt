package claudemirror.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class DeltaTest {
    private val base = json("""{"version":1,"status":"working","message":{"blocks":[{"type":"text","text":"Hel"}]},"gone":true}""")

    @Test fun `a full state replaces the previous one`() {
        assertEquals(json("""{"version":7}"""), applyStateDelta(base, json("""{"version":7}""")))
    }

    @Test fun `patches append text, add items, set and remove fields`() {
        val next = applyStateDelta(base, json("""{"delta":true,"base":1,"version":2,"patches":[
            {"path":["version"],"value":2},
            {"path":["message","blocks",0,"text"],"append":"lo"},
            {"path":["message","blocks",1],"value":{"type":"tool","name":"Bash"}},
            {"path":["status"],"value":"idle"},
            {"path":["gone"],"remove":true}]}"""))
        assertEquals(json("""{"version":2,"status":"idle","message":{"blocks":[{"type":"text","text":"Hello"},{"type":"tool","name":"Bash"}]}}"""), next)
    }

    @Test fun `a patch against another version is refused`() {
        assertThrows(RemoteException::class.java) { applyStateDelta(base, json("""{"delta":true,"base":5,"version":6,"patches":[]}""")) }
        assertThrows(RemoteException::class.java) { applyStateDelta(null, json("""{"delta":true,"base":1,"version":2,"patches":[]}""")) }
    }

    @Test fun `a patch that does not fit the state is refused`() {
        for (patch in listOf("""{"path":["message","blocks",5,"text"],"append":"x"}""", """{"path":["status"],"append":1}""", """{"path":[]}""", """{"path":["status","deeper"],"value":1}""")) {
            assertThrows(patch, RemoteException::class.java) { applyStateDelta(base, json("""{"delta":true,"base":1,"version":1,"patches":[$patch]}""")) }
        }
    }
}
