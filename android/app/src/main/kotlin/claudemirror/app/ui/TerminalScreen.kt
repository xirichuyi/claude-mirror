package claudemirror.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import claudemirror.app.AppModel
import claudemirror.core.RemoteTerminal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.connectbot.terminal.Terminal
import org.connectbot.terminal.TerminalEmulatorFactory

private val Ink = Color(0xFF1F1E1D)
private val Paper = Color(0xFFE8E6E1)

/** A login shell in [directory] over the server's existing SSH connection. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(model: AppModel, hostId: String, directory: String, onBack: () -> Unit) {
    val host = model.hosts.collectAsStateWithLifecycle().value.firstOrNull { it.id == hostId }
    if (host == null) { LaunchedEffect(Unit) { onBack() }; return }
    var attempt by remember { mutableIntStateOf(0) }
    var ended by remember { mutableStateOf<String?>(null) }
    // Keys and size changes arrive on the main thread; sshj breaks the whole connection if it writes there.
    val outgoing = remember(attempt) { Channel<(RemoteTerminal) -> Unit>(Channel.UNLIMITED) }
    var remote by remember { mutableStateOf<RemoteTerminal?>(null) }
    var control by remember { mutableStateOf(false) }
    fun send(bytes: ByteArray) { outgoing.trySend { it.input.write(bytes); it.input.flush() } }
    val emulator = remember(attempt) {
        TerminalEmulatorFactory.create(
            defaultForeground = Paper, defaultBackground = Ink,
            onKeyboardInput = { bytes ->
                val letter = bytes.singleOrNull()?.toInt()?.takeIf { control && it in 0x40..0x7f }
                control = false
                send(if (letter != null) byteArrayOf((letter and 0x1f).toByte()) else bytes)
            },
            onResize = { size -> outgoing.trySend { it.resize(size.columns, size.rows) } },
        )
    }
    DisposableEffect(emulator) { onDispose { remote?.let(::closeOffMain); remote = null; outgoing.close(); emulator.close() } }
    LaunchedEffect(emulator) {
        ended = null
        try {
            val size = emulator.dimensions
            val shell = model.terminal(host, directory, size.columns, size.rows)
            remote = shell
            launch(Dispatchers.IO) { for (send in outgoing) runCatching { send(shell) } }
            withContext(Dispatchers.IO) {
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    val count = shell.output.read(buffer)
                    if (count < 0) break
                    emulator.writeInput(buffer, 0, count)
                }
            }
            ended = "已退出"
        } catch (error: CancellationException) { throw error } catch (error: Exception) { ended = error.message ?: "连接失败" }
        remote?.let(::closeOffMain); remote = null
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(folderName(directory), maxLines = 1, overflow = TextOverflow.StartEllipsis) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = { if (ended != null) IconButton(onClick = { attempt++ }) { Icon(Icons.Filled.Refresh, "重新打开") } },
            )
        },
        containerColor = Ink,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                // A reopened shell gets a fresh view; the old one stays bound to the closed emulator.
                key(emulator) {
                    Terminal(emulator, Modifier.fillMaxSize(), backgroundColor = Ink, foregroundColor = Paper, keyboardEnabled = true, initialFontSize = 13.sp)
                }
                ended?.let { Text(it, Modifier.align(Alignment.BottomCenter).padding(16.dp), color = palette.muted, style = MaterialTheme.typography.labelSmall) }
            }
            // Keys a phone keyboard does not have.
            Row(Modifier.fillMaxWidth().background(Ink).padding(horizontal = 4.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                Key("Esc") { send(byteArrayOf(0x1b)) }
                Key("Tab") { send(byteArrayOf(0x09)) }
                Key("Ctrl", active = control) { control = !control }
                Arrow(Icons.Filled.KeyboardArrowLeft, "D") { send(it) }
                Arrow(Icons.Filled.KeyboardArrowUp, "A") { send(it) }
                Arrow(Icons.Filled.KeyboardArrowDown, "B") { send(it) }
                Arrow(Icons.Filled.KeyboardArrowRight, "C") { send(it) }
            }
        }
    }
}

@Composable
private fun Key(label: String, active: Boolean = false, onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Text(label, color = if (active) MaterialTheme.colorScheme.primary else Paper, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun Arrow(icon: ImageVector, final: String, send: (ByteArray) -> Unit) {
    IconButton(onClick = { send("\u001b[$final".toByteArray()) }) { Icon(icon, null, tint = Paper) }
}

/** Closing sends a packet; sshj breaks the shared connection if that happens on the main thread. */
private fun closeOffMain(shell: RemoteTerminal) { kotlin.concurrent.thread(isDaemon = true, name = "terminal-close") { shell.close() } }
