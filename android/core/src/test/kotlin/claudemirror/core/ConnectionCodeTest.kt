package claudemirror.core

import java.util.Base64
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionCodeTest {
    private val hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJicQEkLt46JTOUutsQxgSDR9f2KuTIuIlLprFr65vfd"
    private val privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"
    private fun code(lines: List<String>) = "cm1." + Base64.getUrlEncoder().withoutPadding().encodeToString((lines.joinToString("\n") + "\n").toByteArray())
    private val valid = listOf("claude-mirror 1", "name box", "host 203.0.113.5", "port 2222", "user alice", "hostkey $hostKey", privateKey)

    @Test fun parsesWhatTheServerPrints() {
        val parsed = ConnectionCode.parse("  " + code(valid).chunked(40).joinToString("\n") + "\n")
        assertEquals(ConnectionCode("box", "203.0.113.5", 2222, "alice", listOf(hostKey), privateKey + "\n"), parsed)
        assertEquals("SHA256:mjcHrS2bpZ8Ka80dhh33ZNb6ZOnNtGHmldVzUeXUbXc".length, parsed.hostKeyFingerprint.length)
        assertTrue(parsed.hostKeyFingerprint.startsWith("SHA256:"))
    }

    @Test fun rejectsCodesThatCouldNotLogInSafely() {
        assertThrows(RemoteException::class.java) { ConnectionCode.parse("cm2.abc") }
        assertThrows(RemoteException::class.java) { ConnectionCode.parse(code(valid.filterNot { it.startsWith("hostkey") })) }
        assertThrows(RemoteException::class.java) { ConnectionCode.parse(code(valid.map { if (it == "user alice") "user a;b" else it })) }
        assertThrows(RemoteException::class.java) { ConnectionCode.parse(code(valid.map { if (it == "host 203.0.113.5") "host -oProxyCommand" else it })) }
        assertThrows(RemoteException::class.java) { ConnectionCode.parse(code(listOf("claude-mirror 2") + valid.drop(1))) }
    }

    @Test fun generatedKeyLoadsInSshj() {
        val key = LoginKey.generate()
        val loaded = SSHClient(DefaultConfig()).loadKeys(key.privateKey, null, null)
        val blob = Base64.getDecoder().decode(key.publicKey.removePrefix("ssh-ed25519 "))
        assertEquals(ConnectionCode("", "", 22, "", listOf(key.publicKey), "").hostKeyFingerprint, fingerprint(loaded.public))
        assertTrue(blob.isNotEmpty())
    }
}
