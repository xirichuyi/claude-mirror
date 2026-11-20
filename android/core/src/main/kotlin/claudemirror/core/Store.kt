package claudemirror.core

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

interface SessionStore {
    fun load(): List<ChatSession>
    fun save(session: ChatSession)
    fun delete(id: String)
}

/** One JSON file per conversation, replaced atomically so a crash never leaves half a file. */
class FileSessionStore(private val directory: File) : SessionStore {
    override fun load(): List<ChatSession> =
        directory.listFiles { file -> file.extension == "json" }.orEmpty().mapNotNull { file ->
            runCatching { MirrorJson.decodeFromString<ChatSession>(file.readText()) }.getOrNull()
        }

    override fun save(session: ChatSession) {
        directory.mkdirs()
        val temporary = File(directory, session.id + ".tmp")
        temporary.writeText(MirrorJson.encodeToString(ChatSession.serializer(), session))
        Files.move(temporary.toPath(), File(directory, session.id + ".json").toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    override fun delete(id: String) {
        File(directory, "$id.json").delete()
    }
}
