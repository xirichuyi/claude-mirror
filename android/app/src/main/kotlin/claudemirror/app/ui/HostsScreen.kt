package claudemirror.app.ui

import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.style.TextOverflow
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import claudemirror.app.AppModel
import claudemirror.app.HostSecret
import claudemirror.core.AuthMethod
import claudemirror.core.ConnectionState
import claudemirror.core.HostConfig

/** What the connection to a server is doing, in the user's words. */
fun ConnectionState?.label(): String = when (this) {
    is ConnectionState.Connected -> if (info.claude == null) "已连接 · 服务器上没有找到 Claude Code" else "已连接"
    ConnectionState.Connecting -> "正在连接…"
    is ConnectionState.Failed -> error.message ?: "连接失败"
    else -> "未连接"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostsScreen(model: AppModel, snackbar: SnackbarHostState, onOpen: (String) -> Unit, onEdit: (String) -> Unit) {
    val hosts by model.hosts.collectAsStateWithLifecycle()
    val connections by model.connections.collectAsStateWithLifecycle()
    Scaffold(
        topBar = { TopAppBar(title = { Text("服务器") }) },
        snackbarHost = { Snackbar(snackbar) },
        floatingActionButton = {
            ExtendedFloatingActionButton(onClick = { onEdit(model.newHostId()) }, icon = { Icon(Icons.Filled.Add, null) }, text = { Text("添加") },
                shape = CircleShape, containerColor = palette.accentFill, contentColor = Color.White)
        },
    ) { padding ->
        if (hosts.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) {
                Spark(Modifier.size(44.dp))
            }
        } else LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            items(hosts, key = { it.id }) { host ->
                val state = connections[host.id]
                Row(
                    Modifier.fillMaxWidth().clickable { onOpen(host.id) }.heightIn(min = 60.dp).padding(start = 16.dp, end = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(host.displayName, style = MaterialTheme.typography.bodyLarge.copy(fontSize = 16.sp), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(state.label(), style = MaterialTheme.typography.bodySmall, color = if (state is ConnectionState.Failed) palette.error else palette.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    IconButton(onClick = { onEdit(host.id) }) { Icon(Icons.Filled.Edit, "编辑", Modifier.size(18.dp), tint = palette.dim) }
                }
            }
        }
    }
}

/** The start of a text file: a key is a few kilobytes, anything much larger was picked by mistake. */
private fun head(input: java.io.InputStream, limit: Int = 65536): String {
    val buffer = CharArray(limit)
    val reader = input.bufferedReader()
    var length = 0
    while (length < limit) length += reader.read(buffer, length, limit - length).takeIf { it > 0 } ?: break
    return String(buffer, 0, length)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostEditScreen(model: AppModel, id: String, onDone: () -> Unit) {
    val existing = remember(id) { model.host(id) }
    val stored = remember(id) { model.secret(id) }
    var name by rememberSaveable { mutableStateOf(existing?.name.orEmpty()) }
    var user by rememberSaveable { mutableStateOf(existing?.user.orEmpty()) }
    var address by rememberSaveable { mutableStateOf(existing?.host.orEmpty()) }
    var port by rememberSaveable { mutableStateOf((existing?.port ?: 22).toString()) }
    var directory by rememberSaveable { mutableStateOf(existing?.directory.orEmpty()) }
    var auth by rememberSaveable { mutableStateOf(existing?.auth ?: AuthMethod.Password) }
    // Secrets are not saved with the screen state, which Android may write to disk.
    var password by remember { mutableStateOf(stored.password.orEmpty()) }
    var privateKey by remember { mutableStateOf(stored.privateKey.orEmpty()) }
    var passphrase by remember { mutableStateOf(stored.passphrase.orEmpty()) }
    var forgetKey by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val pickKey = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val text = uri?.let { runCatching { context.contentResolver.openInputStream(it)?.use { input -> head(input) } }.getOrNull() }
        if (text != null && "PRIVATE KEY" in text) privateKey = text.trim()
        else if (uri != null) model.snackbar.tryEmit("不是私钥文件")
    }
    val portNumber = port.toIntOrNull()?.takeIf { it in 1..65535 }
    val directoryValid = directory.isEmpty() || directory.startsWith("/") || directory == "~" || directory.startsWith("~/")
    val valid = user.isNotBlank() && address.isNotBlank() && directoryValid && portNumber != null &&
        (if (auth == AuthMethod.Password) password.isNotEmpty() else privateKey.isNotBlank())

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (existing == null) "添加服务器" else "编辑服务器") },
            navigationIcon = { IconButton(onClick = onDone) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            val field = Modifier.fillMaxWidth()
            OutlinedTextField(name, { name = it }, field, label = { Text("名称") }, singleLine = true)
            OutlinedTextField(address, { address = it.trim() }, field, label = { Text("地址") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(port, { port = it.filter(Char::isDigit) }, field, label = { Text("SSH 端口") }, singleLine = true, isError = portNumber == null, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            OutlinedTextField(user, { user = it.trim() }, field, label = { Text("用户名") }, singleLine = true)
            OutlinedTextField(
                directory, { directory = it.trim() }, field, label = { Text("目录") }, placeholder = { Text("~") }, singleLine = true, isError = !directoryValid,
            )
            SingleChoiceSegmentedButtonRow(field) {
                SegmentedButton(auth == AuthMethod.Password, { auth = AuthMethod.Password }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("密码") }
                SegmentedButton(auth == AuthMethod.Key, { auth = AuthMethod.Key }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("私钥") }
            }
            if (auth == AuthMethod.Password) {
                OutlinedTextField(password, { password = it }, field, label = { Text("密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            } else {
                OutlinedTextField(
                    privateKey, { privateKey = it }, field, label = { Text("私钥") }, minLines = 4, maxLines = 8,
                    textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    trailingIcon = { IconButton(onClick = { pickKey.launch(arrayOf("*/*")) }) { Icon(Icons.Filled.FolderOpen, "导入文件") } },
                    // A password field to the keyboard: no suggestions, nothing learned from the key.
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                )
                OutlinedTextField(passphrase, { passphrase = it }, field, label = { Text("口令") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            }
            if (existing?.hostKey != null) {
                Text(existing.hostKey.orEmpty(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { forgetKey = !forgetKey }) { Text(if (forgetKey) "保存后重新确认" else "重新确认指纹") }
            }
            Button(
                onClick = {
                    val unchanged = existing != null && existing.host == address && existing.port == portNumber && !forgetKey
                    model.saveHost(
                        HostConfig(id, name.trim(), user, address, portNumber!!, directory.ifEmpty { "~" }, existing?.projects.orEmpty(), auth, hostKey = if (unchanged) existing?.hostKey else null),
                        if (auth == AuthMethod.Password) HostSecret(password = password) else HostSecret(privateKey = privateKey, passphrase = passphrase),
                    )
                    onDone()
                },
                enabled = valid, modifier = field, colors = fillColors(),
            ) { Text("保存") }
            if (existing != null) {
                var confirm by remember { mutableStateOf(false) }
                TextButton(onClick = { if (confirm) { model.deleteHost(existing); onDone() } else confirm = true }, modifier = field) {
                    Text(if (confirm) "确认删除" else "删除服务器", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}
