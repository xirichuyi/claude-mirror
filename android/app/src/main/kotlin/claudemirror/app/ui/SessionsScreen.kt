package claudemirror.app.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import claudemirror.app.AppModel
import claudemirror.core.ChatSession
import claudemirror.core.ConnectionState

/** The state of a conversation in a few words, or null when there is nothing to say. */
fun ChatSession.statusLabel(): String? = when (status) {
    "connecting" -> "正在连接…"
    "working" -> "Claude 正在回复…"
    "permission" -> "等待你的确认"
    "stopping" -> "正在停止…"
    "detached" -> "已断开"
    "error" -> "出错了"
    "stopped" -> "已停止"
    else -> null
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun SessionsScreen(model: AppModel, hostId: String, snackbar: SnackbarHostState, onBack: () -> Unit, onOpen: (String) -> Unit) {
    val hosts by model.hosts.collectAsStateWithLifecycle()
    val host = hosts.firstOrNull { it.id == hostId }
    if (host == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val connections by model.connections.collectAsStateWithLifecycle()
    val state = connections[hostId]
    val all by model.sessions.collectAsStateWithLifecycle()
    val sessions = all.filter { it.hostId == hostId }.sortedByDescending { it.updatedAt }
    var deleting by remember { mutableStateOf<ChatSession?>(null) }
    LaunchedEffect(hostId) {
        if (state !is ConnectionState.Connected && state !is ConnectionState.Connecting) model.connect(host)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(host.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(state.label(), style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            color = if (state is ConnectionState.Failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = { IconButton(onClick = { model.reconnect(host) }) { Icon(Icons.Filled.Refresh, "重新连接") } },
            )
        },
        snackbarHost = { Snackbar(snackbar) },
        floatingActionButton = {
            ExtendedFloatingActionButton(onClick = { onOpen(model.createSession(host).id) }, icon = { Icon(Icons.Filled.Add, null) }, text = { Text("新对话") })
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (state is ConnectionState.Failed) {
                Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text(state.error.message ?: "连接失败", color = MaterialTheme.colorScheme.onErrorContainer)
                        TextButton(onClick = { model.reconnect(host) }) { Text("重试") }
                    }
                }
            }
            (state as? ConnectionState.Connected)?.info?.persistenceWarning?.let { warning ->
                Surface(color = MaterialTheme.colorScheme.tertiaryContainer, modifier = Modifier.fillMaxWidth()) {
                    Text(warning, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onTertiaryContainer, style = MaterialTheme.typography.bodySmall)
                }
            }
            if (sessions.isEmpty()) {
                Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                    Text("还没有对话", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else LazyColumn(Modifier.fillMaxSize()) {
                items(sessions, key = { it.id }) { session ->
                    val preview = session.statusLabel() ?: session.messages.lastOrNull { it.role == "user" }?.text ?: "还没有消息"
                    ListItem(
                        headlineContent = { Text(session.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        supportingContent = { Text(preview, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        trailingContent = {
                            if (session.isBusy && session.status != "detached") CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        },
                        modifier = Modifier.combinedClickable(onClick = { onOpen(session.id) }, onLongClick = { deleting = session }),
                    )
                }
            }
        }
    }

    deleting?.let { session ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("删除对话") },
            text = { Text("从这台手机上删除“${session.name}”。服务器上的 Claude 历史记录不受影响。") },
            confirmButton = { TextButton(onClick = { model.removeSession(session.id); deleting = null }) { Text("删除", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } },
        )
    }
}
