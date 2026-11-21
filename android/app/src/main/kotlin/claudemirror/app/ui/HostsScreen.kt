package claudemirror.app.ui

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
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
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
            ExtendedFloatingActionButton(onClick = { onEdit(model.newHostId()) }, icon = { Icon(Icons.Filled.Add, null) }, text = { Text("添加服务器") })
        },
    ) { padding ->
        if (hosts.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) {
                Text("还没有服务器。添加一台已经装好 Claude Code 的服务器，就可以在手机上继续对话。", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            items(hosts, key = { it.id }) { host ->
                val state = connections[host.id]
                ListItem(
                    headlineContent = { Text(host.displayName) },
                    supportingContent = {
                        Text(
                            host.directory + "\n" + state.label(),
                            color = if (state is ConnectionState.Failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    },
                    trailingContent = { IconButton(onClick = { onEdit(host.id) }) { Icon(Icons.Filled.Edit, "编辑") } },
                    modifier = Modifier.clickable { onOpen(host.id) },
                )
            }
        }
    }
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
    val portNumber = port.toIntOrNull()?.takeIf { it in 1..65535 }
    val valid = user.isNotBlank() && address.isNotBlank() && directory.startsWith("/") && portNumber != null &&
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
            OutlinedTextField(name, { name = it }, field, label = { Text("名称（可不填）") }, singleLine = true)
            OutlinedTextField(address, { address = it.trim() }, field, label = { Text("地址") }, placeholder = { Text("example.com 或 IP") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(port, { port = it.filter(Char::isDigit) }, field, label = { Text("SSH 端口") }, singleLine = true, isError = portNumber == null, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            OutlinedTextField(user, { user = it.trim() }, field, label = { Text("用户名") }, singleLine = true)
            OutlinedTextField(
                directory, { directory = it.trim() }, field, label = { Text("项目目录") }, placeholder = { Text("/home/me/project") }, singleLine = true,
                isError = directory.isNotEmpty() && !directory.startsWith("/"), supportingText = { Text("Claude 在这个目录里工作，需要是绝对路径") },
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
                    supportingText = { Text("粘贴私钥文件的全部内容（以 -----BEGIN 开头）。加密保存在本机，不会上传。") },
                    // A password field to the keyboard: no suggestions, nothing learned from the key.
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                )
                OutlinedTextField(passphrase, { passphrase = it }, field, label = { Text("私钥口令（没有则留空）") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            }
            if (existing?.hostKey != null) {
                Text("已确认的服务器指纹：${existing.hostKey}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { forgetKey = !forgetKey }) { Text(if (forgetKey) "保存后将重新确认指纹" else "服务器重装过？重新确认指纹") }
            }
            Button(
                onClick = {
                    val unchanged = existing != null && existing.host == address && existing.port == portNumber && !forgetKey
                    model.saveHost(
                        HostConfig(id, name.trim(), user, address, portNumber!!, directory, auth, hostKey = if (unchanged) existing?.hostKey else null),
                        if (auth == AuthMethod.Password) HostSecret(password = password) else HostSecret(privateKey = privateKey, passphrase = passphrase),
                    )
                    onDone()
                },
                enabled = valid, modifier = field,
            ) { Text("保存") }
            if (existing != null) {
                var confirm by remember { mutableStateOf(false) }
                TextButton(onClick = { if (confirm) { model.deleteHost(existing); onDone() } else confirm = true }, modifier = field) {
                    Text(if (confirm) "再点一次确认：删除这台服务器和它在本机的对话记录" else "删除服务器", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}
