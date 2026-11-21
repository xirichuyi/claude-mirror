# claude-mirror — Windows 原生版

C# / WinUI 3 客户端，不使用 Electron 或 WebView。SSH.NET 负责连接，复用仓库现有的远端代理与 Claude 持久任务协议。

## 构建

Windows 用户运行发行附件 `Claude-Mirror-Setup-x64.exe`，按提示完成安装。从开始菜单打开 **Claude Mirror**。支持应用内更新的版本会在启动时后台检查并下载稳定版本，可在“更多操作”中手动检查，或在下载完成后选择“重启更新”。Windows 首发版需手动运行首个带更新器的安装包一次；卸载入口在 Windows 设置的“已安装的应用”中。程序按当前用户安装，已有便携版的主机配置仍可使用。

Windows 10 1809+ / Windows 11，安装 .NET 9 SDK 和 Visual Studio 的 Windows 应用开发组件；构建机另需 Node.js 22。

```powershell
npm ci --ignore-scripts
npm run prepare-server -- windows/Resources/server
dotnet test windows/ClaudeMirror.Tests -c Release
dotnet publish windows/ClaudeMirror.App -c Release -r win-x64 -p:Platform=x64 -o windows/dist/claude-mirror
```

构建机安装 Inno Setup 6 后执行 `./windows/build-installer.ps1`，生成自包含安装程序。也可保留完整发布目录以便携方式运行。本机用户无需安装 .NET、Node.js 或 Claude；远端只需要 Linux/macOS 和 SSH。连接后应用会检查服务器环境：缺少 Claude Code 或 Node.js 时可一键安装（装在用户目录，无需管理员权限），Claude 未登录时可打开终端登录。新手请先看[入门指南](../docs/getting-started.md)。

## 已接入

- 多主机命名，地址可直接写 `用户名@主机`，端口和名称收在高级选项；密码或私钥文件认证；密码仅保存在当前连接过程内存中。
- 服务器环境检查：缺 Node.js / Claude Code 一键安装，Claude 未登录引导终端登录，SSH 断开会结束后台任务时给出处理命令；连接失败给出原因说明。
- 密码登录成功后可一键设置免密登录（使用 Windows 自带的 ssh-keygen 生成专用密钥）。
- 首次确认主机指纹，指纹变更拒绝连接；SSH keepalive。
- 添加服务器时可以从 `~/.ssh/config` 导入主机（HostName、User、Port、IdentityFile；不处理 `Match` 块）。配置里写了 ProxyJump 的主机会自动改用系统 SSH。
- 登录方式“系统 SSH”：用 Windows 自带的 OpenSSH 客户端连接，和在终端里输入 `ssh` 一样读取 `~/.ssh/config`、使用 ssh-agent 里的密钥；可以填跳板机（`ssh -J`），经跳板机时走跳板机自己的 SSH 通道，不在本机开中转端口。这种方式不能输入密码或私钥口令（带口令的私钥先 `ssh-add`）；主机密钥沿用 `known_hosts`，没见过的主机需要先在终端里确认一次。
- Full Access 权限模式：跳过 Claude 的操作确认。用 root 登录时需要在新对话里填写一个已配置好的普通执行账号（例如 `claude-runner`），这类对话的历史会和 root 自己的一起列出。
- 断线自动重连：用无口令私钥或系统 SSH 登录的服务器会按 1、2、5、10、30 秒的间隔自动重连，保留当前对话并重新订阅仍在运行的远端任务。密码和私钥口令不会留存，所以这类服务器断线后需要手动重新连接。主机指纹变化或私钥被拒绝时停止重试。
- 端口转发（“更多操作”里）：把服务器 127.0.0.1 上的端口接到本机 127.0.0.1，可随时关闭；自动重连后会恢复。
- 项目分组、分页同步历史索引、选中后读取消息。
- 会话管理（右键侧栏里的对话）：重命名、固定、归档、详情、从列表移除；这些只保存在本机，不改动服务器上的对话记录。右键项目可以把该目录的全部对话记录移到服务器的废纸篓。
- 新会话、历史续聊、远端持久任务、停止。
- 对话：工具调用显示为可展开的卡片（命令、文件、diff、任务清单、输出和运行状态），思考过程可折叠；代码块保留长行、横向滚动，超过 380 像素在块内滚动；历史消息里的工具结果并入对应的工具卡片。
- 权限请求显示在输入框上方的卡片里：直接看到命令或 diff，可以选择问题的选项、应用远端建议的权限规则、拒绝时附上修改意见；输入框工具栏可切换权限模式。
- 多个对话可以同时回复：对话正在回复、等你确认或有排队消息时切到别的对话或新建对话，它会在后台继续，排队的消息照常依次发送。侧栏顶部的“后台对话”列出它们的状态（回复中、等你确认、已暂停、有新回复），点一下回到离开时的样子。断线后后台对话的队列会暂停；换服务器时它们不再跟随。
- 回复进行中发送的消息进入队列，回复结束后依次发送；回复失败或被停止时队列暂停，由你决定是否继续。
- 跨消息选择文本：“更多操作”里的“对话文本”（或回复下方的“跨消息选择文本”）把整个对话的文字放进一个标签页，可以从一条消息拖选到另一条、全选、复制。它只包含消息文字，不含工具调用和思考过程；对话气泡里仍然只能在一段文字内选择。
- 回复结束后可以复制整条回复，或预览并回退这条回复改动的文件（需要远端任务仍在运行）。
- 远端模型/命令列表；命令填入输入框，发送后由远端处理。
- 工作区（“更多操作”里）：Git 变更列表和并排 diff、在项目文件中搜索（Ctrl+Shift+F）、按文件名快速打开（Ctrl+P）、从当前 HEAD 新建 worktree、PDF 预览（前 30 页，标签页上可下载原文件）。这些和文件编辑器共用对话右侧的标签页。
- 状态页（“更多操作”里）：服务器和环境检查结果、账号用量、对话用量（最近一轮和各模型的 token、远端报告的费用）、上下文用量、MCP 服务器（重连、启用/停用）、已加载的插件列表和重新加载、Agent 列表、停止后台任务。后面几项来自对话的远端任务，发送过消息后才有数据。
- 设置（“更多操作”里）：外观可选跟随系统、浅色或深色，选择会保存。
- 远端文件浏览器里可以新建文件和文件夹，右键条目可以重命名、删除（删除在菜单里二次确认，不进废纸篓）。
- 远端目录浏览，文本/图片预览和下载，选择文件/拖放上传；附件按内容哈希存入远端缓存，相同内容复用路径。
- 会话 ID 和远端任务 ID 保存在 LocalAppData/claude-mirror，可在重连选择历史会话时重新订阅。

## 当前边界

聊天和 Markdown 文件共用原生渲染器，支持标题、引用、表格、列表、任务标记、链接、行内代码和带语言名的围栏代码块。打开“远端文件”，选择文本文件即可在聊天右侧打开标签。使用“编辑”和 Ctrl+S 保存；保存遇到版本冲突时保留草稿。完整预览和编辑上限为 1 MB，窄窗口可用“返回对话”切换。

表单类交互（elicitation）和反向访问尚未移植。目录切换请新建会话，运行中的任务仍使用原目录。

原生 Windows 窗口交互须在 Windows 实机验收；macOS 只能验证共享 C# 核心和远端协议。CI 提供 Windows 编译、测试和自包含 x64 ZIP 工件。安装程序和客户端当前均未签名。

## 验证

核心单元测试覆盖状态增量、乱序保护、Shell 参数引用和本地状态持久化。已通过 `axi` 实测 SSH 连接、历史索引、文件目录、真实 Claude 回复与会话能力读取。Windows CI 另外检查编译和原生窗口 Loaded 事件，再输出 ZIP。

集成测试默认跳过。维护者可以设置 `MIRROR_SMOKE_HOST`、`MIRROR_SMOKE_PORT`、`MIRROR_SMOKE_USER`、`MIRROR_SMOKE_KEY`、`MIRROR_SMOKE_FINGERPRINT` 和 `MIRROR_SMOKE_RESOURCES` 运行只读连接检查；额外设置 `MIRROR_SMOKE_CHAT=1` 会创建一条测试会话，产生一次模型请求，随后关闭测试任务。私钥和真实主机配置不要提交到仓库。

### 演示场景和截图

不连接服务器也可以打开真实窗口：设置 `CLAUDE_MIRROR_DEMO=home`、`chat`、`permission` 或 `finished` 后启动，界面使用内置的演示数据，不读写已保存的主机。可选 `CLAUDE_MIRROR_THEME=light|dark`、`CLAUDE_MIRROR_SIZE=1280x860`、`CLAUDE_MIRROR_SCROLL=0`；设置 `CLAUDE_MIRROR_SNAPSHOT=路径.png` 会把窗口内容保存为图片后退出。

```powershell
./windows/capture-screenshots.ps1 windows/dist/claude-mirror/claude-mirror.exe windows/dist/screenshots
```

CI 每次都会生成这些截图，并作为 `claude-mirror-windows-screenshots` 产物上传。
