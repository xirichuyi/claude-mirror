# 高级功能



## 服务器反向连接本机

在机器菜单中右键服务器，勾选“允许此服务器反向连接本机”，该服务器就能通过本应用已有的 SSH 连接登录这台 Mac。这项功能不用另开隧道，也不需要公网 IP 或端口映射；默认关闭，需要每台服务器单独开启，目前只有 macOS 原生客户端支持。

开启后，应用在每次连接或重连时会做以下几件事：

1. 在服务器的 `~/.claude-mirror/reverse/`（权限 700）里绑定一个仅本用户可访问的 Unix socket，转发到本机的 22 端口。这里不监听 TCP 端口；断线留下的旧 socket 会先删除再重新绑定。
2. 在服务器上生成一把专用密钥，加入本机的 `~/.ssh/authorized_keys`，并加上 `from="127.0.0.1,::1"` 限制：这把密钥只能经由该通道使用，其他已有的行保持原样。
3. 把本机的 ed25519 主机公钥写到服务器上，服务器首次连接时不用手动核对指纹。
4. 生成一份 ssh_config 并开启连接复用。菜单中的“复制反向连接命令”会得到 `ssh -F ~/.claude-mirror/reverse/<名称>.config <名称>`；`scp`、`rsync -e` 加上同样的 `-F` 参数即可使用。
5. 连接期间阻止 Mac 因闲置自动休眠，合盖或手动睡眠不受影响。

取消勾选后，应用会立即从 `authorized_keys` 删除这一行，即使当前离线也会删除；如果服务器在线，还会关闭它已打开的会话并删除 socket。

需要满足的条件：本机已开启“系统设置 → 通用 → 共享 → 远程登录”；服务器安装了 `socat`；应用正在运行并已连接该服务器。退出应用、Mac 进入睡眠或网络断开时，反向连接也会中断。

**开启期间，服务器上任何能读取该专用密钥的程序或用户，都能以你的身份登录这台 Mac。** 只对你信任的服务器开启，不用时关闭。

反向流量和聊天流量共用同一条 SSH 连接。实测在约 300ms 延迟的跨境线路上，反向连接的速度与单独开隧道相当；但通过它传输大文件时，应用里的操作会变慢 50%–100%，传完即恢复。

## 跨机器同步记忆和会话

`scripts/agent-sync.cts` 让 VPS 和本地的 Agent 共用记忆，并能接手对方的会话。账号只在 VPS 上登录，同步范围不包含凭据。机器之间只需要能用 SSH 互连：本地直连 VPS 公网，或使用 WireGuard、Tailscale 等内网地址都可以。同步不经过第三方服务，也不转发模型流量。

| 内容 | 同步方式 |
| --- | --- |
| Claude 项目记忆 | 双向同步；同一文件冲突时两个版本都保留（`*.conflict-*`），`MEMORY.md` 按行合并 |
| 会话交接记录 | 每个会话生成脱敏 Markdown，只含对话和工具摘要，不含工具输出和思考内容 |
| 原始会话 | 默认本地的上传到 VPS；在本地 `config.json` 设 `"uploadRaw": false` 后留在本地，VPS 运行 `resume` 时通过 `--peer` 配置的 SSH 连接读取 |
| 凭据、设置、历史 | 从不读取或同步 |

Claude Code 的 `SessionStart`、`Stop`、`SessionEnd` hook 和 Codex 的 `notify` 触发同步，每 5 分钟的定时任务兜底。其他 Agent 可以在任务结束时调用 `agent-sync sync --quiet` 接入。需要 macOS、Linux 或 WSL，以及 Node.js、git、rsync。

```sh
# 首次运行或更新源码后，在仓库根目录编译
npm ci --ignore-scripts
npm run build

# VPS
node build/scripts/agent-sync.cjs install --role hub --host vps

# 本地：确认能免密 ssh 到 VPS 后运行
node build/scripts/agent-sync.cjs install --role spoke --host laptop --hub root@<VPS 地址> --hub-host vps

# VPS：可选，任务完成后立刻通知本地。需要 VPS 能 SSH 到本地，
# 例如开启上文的“服务器反向连接本机”，再在 VPS 的 ~/.ssh/config 中为本机配置别名
~/.agent-sync/bin/agent-sync install --peer <本机的 SSH 别名>
```

不同机器上路径不同的项目，如果 `origin` 相同会自动对应；否则在两边各运行一次 `agent-sync link <共享名> <路径>`。

```sh
agent-sync sessions --project   # 查看当前项目在各机器上的会话
agent-sync show <会话ID>        # 读取交接记录
agent-sync resume <会话ID>      # 把原始会话下载到本机，并给出恢复命令
agent-sync doctor               # 检查 hub、对端连通性和记忆冲突
```

同一个会话不要同时在两台机器上继续，否则会分叉成两条历史。原始会话没有脱敏，只保存在你自己的机器上。

## 复制给 Agent 的使用指引

把下面整段交给你的编程 Agent，并补充本机平台及 SSH 主机；不要在提示词中填密码或 API Key。

```text
请帮我部署和使用Tether。
项目：https://github.com/xirichuyi/tether
我的本机系统：[填写系统与 CPU 架构]
目标 SSH 主机：[填写 SSH config 别名或 user@host]
远端项目目录：[填写绝对路径]

请先阅读仓库 README，再按实际平台操作：
1. 确认本机平台与架构。Apple Silicon macOS 14+ 优先使用 GitHub Releases
   的 DMG；Windows x64 查看 windows/README.md 的原生预览版和 CI ZIP；
   Linux 检查 Electron 源码入口，不要假设存在正式安装包。
2. 验证 SSH 连通性和主机身份。沿用我的 SSH 配置，不关闭主机指纹验证。
3. 检查远端 Node.js 和 Claude Code。若 Claude 缺失，运行仓库的
   scripts/setup-remote.sh 连接目标主机并安装；保留已有安装及认证配置。
4. 需要账户登录时让我在远端交互式终端完成，不读取或复制 auth.json、
   API Key、私钥内容，也不要把凭据写进仓库。
5. 启动客户端，添加有名称的主机，选择远端项目并加载历史。
6. 用无敏感内容的临时样例确认：聊天附件进入远端临时目录；同名同内容
   复用路径，同名不同内容产生新路径；文件面板上传则写入当前目录。
7. 验证文件预览、模型选择和连接恢复，说明已验证内容及平台限制。
   不删除我的项目文件，不运行与任务无关的命令，不自动发送真实工作内容。
```
