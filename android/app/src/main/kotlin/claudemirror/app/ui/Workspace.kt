package claudemirror.app.ui

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import claudemirror.app.AppModel
import claudemirror.core.FilePreview
import claudemirror.core.GitStatus
import claudemirror.core.HostConfig
import claudemirror.core.RemoteListing

/** Walks the server's files from [start]; a file opens in place, Git shows what changed under the current folder. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FilesScreen(model: AppModel, hostId: String, start: String, onBack: () -> Unit, onGit: (String) -> Unit) {
    val host = model.hosts.collectAsStateWithLifecycle().value.firstOrNull { it.id == hostId }
    if (host == null) { LaunchedEffect(Unit) { onBack() }; return }
    var path by rememberSaveable { mutableStateOf(start) }
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember { mutableStateOf<Loaded<RemoteListing>>(Loaded.Waiting) }
    var opened by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(path, attempt) { state = Loaded.Waiting; state = load { model.entries(host, path) } }
    val listing = (state as? Loaded.Ready)?.value

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(listing?.path ?: path, style = CodeStyle, maxLines = 1, overflow = TextOverflow.StartEllipsis) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = {
                    IconButton(onClick = { listing?.let { path = it.parent } }, enabled = listing != null && listing.parent != listing.path) { Icon(Icons.Filled.ArrowUpward, "上一级") }
                    IconButton(onClick = { onGit(listing?.path ?: path) }) { Icon(Icons.Filled.AccountTree, "Git") }
                    IconButton(onClick = { attempt++ }) { Icon(Icons.Filled.Refresh, "刷新") }
                },
            )
        },
    ) { padding ->
        Loading(state, Modifier.fillMaxSize().padding(padding), onRetry = { attempt++ }) { shown ->
            if (shown.entries.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Icon(Icons.Filled.Folder, "空文件夹", tint = palette.dim) }
            else LazyColumn(Modifier.fillMaxSize()) {
                items(shown.entries, key = { it.path }) { entry ->
                    ListItem(
                        leadingContent = {
                            Icon(
                                when { entry.broken -> Icons.Outlined.LinkOff; entry.directory -> Icons.Filled.Folder; else -> Icons.AutoMirrored.Outlined.InsertDriveFile },
                                null, tint = palette.muted,
                            )
                        },
                        headlineContent = { Text(entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        trailingContent = { if (!entry.directory && !entry.broken) Text(byteSize(entry.size), style = MaterialTheme.typography.labelSmall, color = palette.muted) },
                        modifier = Modifier.clickable(enabled = !entry.broken) { if (entry.directory) path = entry.path else opened = entry.path },
                    )
                }
            }
        }
    }
    opened?.let { file -> FileViewer(model, host, file, onDismiss = { opened = null }) }
}

/** The changed files of the repository holding [directory]; one opens on its diff. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GitScreen(model: AppModel, hostId: String, directory: String, onBack: () -> Unit, onFolder: (String) -> Unit) {
    val host = model.hosts.collectAsStateWithLifecycle().value.firstOrNull { it.id == hostId }
    if (host == null) { LaunchedEffect(Unit) { onBack() }; return }
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember { mutableStateOf<Loaded<GitStatus>>(Loaded.Waiting) }
    var opened by remember { mutableStateOf<claudemirror.core.GitChange?>(null) }
    LaunchedEffect(attempt) { state = Loaded.Waiting; state = load { model.gitStatus(host, directory) } }
    val status = (state as? Loaded.Ready)?.value

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(status?.branch?.removePrefix("No commits yet on ")?.substringBefore("...")?.ifEmpty { null } ?: folderName(directory), maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = { IconButton(onClick = { attempt++ }) { Icon(Icons.Filled.Refresh, "刷新") } },
            )
        },
    ) { padding ->
        Loading(state, Modifier.fillMaxSize().padding(padding), onRetry = { attempt++ }) { shown ->
            when {
                !shown.repository -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("不是 Git 仓库", color = palette.muted) }
                shown.files.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("没有改动", color = palette.muted) }
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(shown.files, key = { it.status + it.path }) { change ->
                        ListItem(
                            leadingContent = {
                                Text(change.status.trim().take(1).replace("?", "U"), Modifier.width(18.dp), style = CodeStyle, fontWeight = FontWeight.Bold, color = changeColor(change.status))
                            },
                            headlineContent = { Text(folderName(change.relative), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            supportingContent = {
                                change.relative.substringBeforeLast('/', "").takeIf { it.isNotEmpty() }?.let { Text(it, maxLines = 1, overflow = TextOverflow.StartEllipsis, style = CodeStyle, color = palette.muted) }
                            },
                            // Git lists a new folder once, not its files: it opens as a folder.
                            modifier = Modifier.clickable { if (change.relative.endsWith("/")) onFolder(change.path) else opened = change },
                        )
                    }
                }
            }
        }
    }
    opened?.let { change ->
        Viewer(change.relative, onDismiss = { opened = null }) {
            var diff by remember { mutableStateOf<Loaded<String>>(Loaded.Waiting) }
            var again by remember { mutableIntStateOf(0) }
            LaunchedEffect(again) { diff = Loaded.Waiting; diff = load { model.gitDiff(host, change.path) } }
            Loading(diff, Modifier.fillMaxSize(), onRetry = { again++ }) { text ->
                if (text.isBlank()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("无差异", color = palette.muted) }
                else Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp)) { CodeBox(text, "diff", title = null) }
            }
        }
    }
}

@Composable
private fun changeColor(status: String) = when {
    'D' in status -> palette.removed
    status.startsWith("??") || 'A' in status -> palette.added
    else -> palette.warning
}

@Composable
private fun FileViewer(model: AppModel, host: HostConfig, file: String, onDismiss: () -> Unit) = Viewer(folderName(file), onDismiss) {
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember { mutableStateOf<Loaded<FilePreview>>(Loaded.Waiting) }
    LaunchedEffect(attempt) { state = Loaded.Waiting; state = load { model.preview(host, file) } }
    Loading(state, Modifier.fillMaxSize(), onRetry = { attempt++ }) { preview ->
        val image = remember(preview) {
            preview.inlineData?.takeIf { preview.kind == "image" }?.let { runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull() }?.let(::screenBitmap)
        }
        when {
            image != null -> Image(image, folderName(file), Modifier.fillMaxSize().padding(12.dp), contentScale = ContentScale.Fit)
            preview.kind == "text" && preview.text != null -> Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp)) {
                CodeBox(preview.text!!, file.substringAfterLast('.', ""), title = if (preview.truncated) byteSize(preview.size) else null)
            }
            else -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Text(preview.reason ?: "无法预览", color = palette.muted, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Viewer(title: String, onDismiss: () -> Unit, content: @Composable () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(title, style = CodeStyle, maxLines = 1, overflow = TextOverflow.StartEllipsis) },
                    navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, "关闭") } },
                )
            },
        ) { padding -> Box(Modifier.fillMaxSize().padding(padding)) { content() } }
    }
}

/** A few hundred KB of PNG can be tens of thousands of pixels across; it is decoded no larger than a screen needs. */
private fun screenBitmap(bytes: ByteArray): androidx.compose.ui.graphics.ImageBitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048) sample *= 2
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}

private fun byteSize(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "%.1f KB".format(bytes / 1024.0)
    else -> "%.1f MB".format(bytes / 1024.0 / 1024.0)
}
