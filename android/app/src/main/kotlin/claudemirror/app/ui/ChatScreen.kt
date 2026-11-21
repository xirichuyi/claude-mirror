package claudemirror.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import claudemirror.app.AppModel
import claudemirror.core.ChatSession
import claudemirror.core.ConnectionState
import kotlinx.serialization.json.JsonObject

private val PermissionModes = listOf(
    null to "默认：每次操作先询问",
    "acceptEdits" to "自动接受文件修改",
    "plan" to "计划模式：只读不改",
    "bypassPermissions" to "Full Access：不再询问",
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(model: AppModel, sessionId: String, snackbar: SnackbarHostState, onBack: () -> Unit) {
    val sessions by model.sessions.collectAsStateWithLifecycle()
    val session = sessions.firstOrNull { it.id == sessionId }
    if (session == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val connections by model.connections.collectAsStateWithLifecycle()
    var draft by rememberSaveable(sessionId) { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(session.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        (session.statusLabel() ?: session.model)?.let {
                            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Filled.Tune, "权限模式") }
                    DropdownMenu(menu, onDismissRequest = { menu = false }) {
                        for ((mode, label) in PermissionModes) {
                            DropdownMenuItem(
                                text = { Text(label) },
                                leadingIcon = { RadioButton(session.preferences.permissionMode == mode, null) },
                                enabled = session.remoteTask == null,
                                onClick = { menu = false; model.configure(sessionId, session.preferences.copy(permissionMode = mode)) },
                            )
                        }
                    }
                },
            )
        },
        snackbarHost = { Snackbar(snackbar) },
    ) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()) {
            // What is left of a phone on its side, or under its keyboard: the composer takes one line.
            val compact = maxHeight < 320.dp
            val wide = maxWidth >= 600.dp
            val queueRoom = minOf(maxHeight / 4, 144.dp)
            Column(Modifier.fillMaxSize()) {
                if (session.status == "detached" || session.transportError != null) {
                    val host = model.host(session.hostId)
                    Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth()) {
                        Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                session.transportError ?: (connections[session.hostId] as? ConnectionState.Failed)?.error?.message ?: "连接已断开，回复仍在服务器上进行",
                                Modifier.weight(1f), color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.bodySmall,
                            )
                            if (host != null) TextButton(onClick = { model.reconnect(host) }) { Text("重新连接") }
                        }
                    }
                }
                // The composer keeps its place below, however short the window and however much waits above it.
                Column(Modifier.weight(1f)) {
                    Transcript(session, Modifier.weight(1f)) { permission, answer -> model.respond(sessionId, permission, answer) }
                    // Editing a queued message must not throw away what is already being written.
                    Queue(session, model, queueRoom, onEdit = { item -> draft = if (draft.isBlank()) item else draft.trimEnd() + "\n" + item })
                }
                Composer(
                    session, draft, compact, wide, onDraft = { draft = it },
                    onSend = { steer -> if (model.submit(sessionId, draft, steer)) draft = "" },
                    onStop = { model.stop(sessionId) },
                )
            }
        }
    }
}

@Composable
private fun Transcript(session: ChatSession, modifier: Modifier, onAnswer: (permission: String, JsonObject) -> Unit) {
    val list = rememberLazyListState()
    // One row per block, so a long reply only redraws the part that is still being written.
    val rows = remember(session.messages) {
        session.messages.flatMap { message ->
            if (message.role == "user") listOf(Triple(message.id, message, -1))
            else message.blocks.orEmpty().indices.map { Triple(message.id + ":" + it, message, it) } + Triple(message.id + ":end", message, -2)
        }
    }
    val last = session.messages.lastOrNull()
    if (rows.isEmpty() && session.permissions.isEmpty()) {
        Box(modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
            Text("在 ${session.directory} 里开始对话。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    // Whether the view keeps up with the reply. Only the reader's own scrolling changes it:
    // text arriving, the keyboard opening or the screen turning must not end it.
    var following by rememberSaveable { mutableStateOf(true) }
    val reader = remember(list) {
        object : NestedScrollConnection {
            // Only gestures come through here; the scrolling done below does not.
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (consumed.y > 0f) following = false else if (!list.canScrollForward) following = true
                return Offset.Zero
            }
        }
    }
    val end by rememberUpdatedState(rows.size)
    LaunchedEffect(list) {
        // Whatever makes the list longer than the window, the end comes back into view.
        snapshotFlow { following && list.canScrollForward && !list.isScrollInProgress }.collect {
            var place = -1 to -1
            while (following && list.canScrollForward && !list.isScrollInProgress) {
                list.scrollToItem(end)
                // As far as it goes: a request taller than the window starts at its top.
                if (place == list.firstVisibleItemIndex to list.firstVisibleItemScrollOffset) break
                place = list.firstVisibleItemIndex to list.firstVisibleItemScrollOffset
                withFrameNanos { }
            }
        }
    }
    // A request Claude is waiting on is brought into view, wherever the reader was, and stays there.
    val asked = session.permissions.firstOrNull()?.id
    LaunchedEffect(asked) {
        if (asked != null) { following = true; list.scrollToItem(rows.size) }
    }
    LazyColumn(modifier.fillMaxWidth().nestedScroll(reader), state = list) {
        items(rows.size, key = { rows[it].first }) { index ->
            val (_, message, part) = rows[index]
            when (part) {
                -1 -> UserBubble(message.text.orEmpty())
                -2 -> Column(Modifier.padding(horizontal = 16.dp)) {
                    message.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                    if (message.interrupted == true) Text("已停止", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
                }
                else -> BlockView(message.blocks!![part])
            }
        }
        item(key = "status") {
            // A pending request is shown by its own card.
            if (session.isBusy && session.status != "permission") {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (session.status != "detached") CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text(
                        if (session.status == "working") last?.activity?.takeIf { it.isNotBlank() } ?: "Claude 正在回复…" else session.statusLabel().orEmpty(),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        // In the list rather than pinned over it: a long command must not push the reply or the composer off screen.
        items(session.permissions, key = { "permission:" + it.id }) { permission ->
            PermissionCard(permission) { answer -> onAnswer(permission.id, answer) }
        }
    }
}

/** Messages waiting for the current reply to end. Each can go into the reply now, back to the editor, or away. */
@Composable
private fun Queue(session: ChatSession, model: AppModel, room: Dp, onEdit: (String) -> Unit) {
    if (session.queue.isEmpty()) return
    HorizontalDivider()
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val waiting = (session.queuePaused || session.queueHeld) && session.remoteTask == null
            Text(
                when {
                    session.queueHeld -> "排队 ${session.queue.size} 条 · 服务器地址已更改，确认后才会发送"
                    waiting -> "排队 ${session.queue.size} 条 · 已暂停"
                    else -> "排队 ${session.queue.size} 条 · 回复结束后依次发送"
                },
                Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (waiting) TextButton(onClick = { model.resumeQueue(session.id) }) { Text("继续发送") }
            TextButton(onClick = { model.clearQueue(session.id) }) { Text("清空") }
        }
        Column(Modifier.heightIn(max = room).verticalScroll(rememberScrollState())) {
            for (item in session.queue) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(item.text, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                    if (session.remoteTask != null) IconButton(onClick = { model.steer(session.id, item.id) }) { Icon(Icons.Filled.Bolt, "立即发送：插入当前回复") }
                    IconButton(onClick = { model.cancelQueued(session.id, item.id); onEdit(item.text) }) { Icon(Icons.Filled.Edit, "编辑") }
                    IconButton(onClick = { model.cancelQueued(session.id, item.id) }) { Icon(Icons.Filled.Close, "移除") }
                }
            }
        }
    }
}

@Composable
private fun Composer(
    session: ChatSession, draft: String, compact: Boolean, wide: Boolean,
    onDraft: (String) -> Unit, onSend: (steer: Boolean) -> Unit, onStop: () -> Unit,
) {
    val replying = session.remoteTask != null
    val ready = draft.isNotBlank()
    val actions: @Composable () -> Unit = {
        if (session.isBusy) {
            FilledIconButton(
                onClick = onStop, enabled = session.status != "stopping",
                colors = IconButtonDefaults.filledIconButtonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError),
            ) { Icon(Icons.Filled.Stop, "停止") }
        }
        if (replying) {
            FilledTonalIconButton(onClick = { onSend(true) }, enabled = ready) { Icon(Icons.Filled.Bolt, "插队：让 Claude 在下一步读取") }
            FilledIconButton(onClick = { onSend(false) }, enabled = ready) { Icon(Icons.AutoMirrored.Filled.Send, "排队：回复结束后发送") }
        } else {
            FilledIconButton(onClick = { onSend(false) }, enabled = ready) { Icon(Icons.AutoMirrored.Filled.Send, "发送") }
        }
    }
    // How full Claude's context window is, as last reported by the server.
    val meter: @Composable (bar: Boolean) -> Unit = { bar ->
        session.context?.let { context ->
            if (bar) LinearProgressIndicator(
                progress = { context.fraction }, modifier = Modifier.width(56.dp),
                trackColor = MaterialTheme.colorScheme.surfaceVariant, gapSize = 0.dp, drawStopIndicator = {},
            )
            Text("上下文 ${context.label}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = if (compact) 4.dp else 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        // The field keeps its place in both layouts, so it keeps the keyboard when one turns into the other.
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                draft, onDraft,
                Modifier.weight(1f).onPreviewKeyEvent { event ->
                    // Hardware keyboards only; on-screen keyboards insert the newline themselves.
                    if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    when {
                        event.key == Key.Escape && session.isBusy -> { onStop(); true }
                        event.key == Key.Enter && !event.isShiftPressed && ready -> { onSend(replying && (event.isCtrlPressed || event.isMetaPressed)); true }
                        else -> false
                    }
                },
                placeholder = { Text(if (replying) "回复中：可以排队，或插入当前回复" else "给 Claude 发消息", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                maxLines = if (compact) 2 else 6,
            )
            if (compact) {
                if (wide) meter(false)
                actions()
            }
        }
        if (!compact) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) { meter(true) }
            actions()
        }
    }
}
