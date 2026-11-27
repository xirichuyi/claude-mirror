package claudemirror.core

import org.junit.Assert.assertEquals
import org.junit.Test

class MembersTest {
    @Test fun parsesMemberLines() {
        assertEquals(
            listOf(RemoteMember("alice", "SHA256:x"), RemoteMember("bob", "")),
            RemoteMembers.parse(listOf("member alice SHA256:x", "noise", "member bob -", "")),
        )
    }

    @Test fun quotesEveryArgument() {
        assertEquals(
            "sh -c 'command -v bash >/dev/null 2>&1 || exit 1; exec bash -s -- '\\''--remove-user'\\'' '\\''a b'\\'' 2>&1'",
            RemoteMembers.command(listOf("--remove-user", "a b")),
        )
    }
}
