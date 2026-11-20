# claude-mirror — Windows 原生版

C# / WinUI 3 客户端，不使用 Electron 或 WebView。SSH.NET 负责连接，复用仓库现有的远端代理与 Claude 持久任务协议。

## 构建

Windows 用户运行发行附件 `Claude-Mirror-Setup-x64.exe`，按提示完成安装。从开始菜单打开 **Claude Mirror**。支持应用内更新的版本会在启动时后台检查并下载稳定版本，可在“更多操作”中手动检查，或在下载完成后选择“重启更新”。Windows 首发版需手动运行首个带更新器的安装包一次；卸载入口在 Windows 设置的“已安装的应用”中。程序按当前用户安装，已有便携版的主机配置仍可使用。

Windows 10 1809+ / Windows 11，安装 .NET 9 SDK 和 Visual Studio 的 Windows 应用开发组件；构建机另需 Node.js 22。

```powershell
npm ci --ignore-scripts
node macos/scripts/prepare-server.cjs windows/Resources/server
dotnet test windows/ClaudeMirror.Tests -c Release
dotnet publish windows/ClaudeMirror.App -c Release -r win-x64 -p:Platform=x64 -o windows/dist/claude-mirror
```

构建机安装 Inno Setup 6 后执行 `./windows/build-installer.ps1`，生成自包含安装程序。也可保留完整发布目录以便携方式运行。本机用户无需安装 .NET、Node.js 或 Claude；远端只需要 Linux/macOS 和 SSH。连接后应用会检查服务器环境：缺少 Claude Code 或 Node.js 时可一键安装（装在用户目录，无需管理员权限），Claude 未登录时可打开终端登录。新手请先看[入门指南](../docs/getting-started.md)。

## 已接入

- 多主机命名，地址可直接写 `用户名@主机`，端口和名称收在高级选项；密码或私钥文件认证；密码仅保存在当前连接过程内存中。
- 服务器环境检查：缺 Node.js / Claude Code 一键安装，Claude 未登录引导终端登录，SSH 断开会结束后台任务时给出处理命令；连接失败给出原因说明。
- 密码登录成功后可一键设置免密登录（使用 Windows 自带的 ssh-keygen 生成专用密钥）。
- 首次确认主机指纹，指纹变更拒绝连接；SSH keepalive。
- 项目分组、分页同步历史索引、选中后读取消息。
- 新会话、历史续聊、远端持久任务、停止、工具权限确认与 AskUserQuestion 回答。
- 远端模型/命令列表；命令填入输入框，发送后由远端处理。
- 远端目录浏览，文本/图片预览和下载，选择文件/拖放上传；附件按内容哈希存入远端缓存，相同内容复用路径。
- 会话 ID 和远端任务 ID 保存在 LocalAppData/claude-mirror，可在重连选择历史会话时重新订阅。

## 当前边界

聊天和 Markdown 文件共用原生渲染器，支持标题、引用、表格、列表、任务标记、链接、行内代码和带语言名的围栏代码块。打开“远端文件”，选择文本文件即可在聊天右侧打开标签。使用“编辑”和 Ctrl+S 保存；保存遇到版本冲突时保留草稿。完整预览和编辑上限为 1 MB，窄窗口可用“返回对话”切换。

复杂命令的专用交互卡片、文件删除、自动重连、SSH config/ProxyJump/agent、反向访问和可视化 usage 尚未移植。私钥需要手动选择，不自动读取 macOS 配置。目录切换请新建会话，运行中的任务仍使用原目录。

原生 Windows 窗口交互须在 Windows 实机验收；macOS 只能验证共享 C# 核心和远端协议。CI 提供 Windows 编译、测试和自包含 x64 ZIP 工件。安装程序和客户端当前均未签名。

## 验证

核心单元测试覆盖状态增量、乱序保护、Shell 参数引用和本地状态持久化。已通过 `axi` 实测 SSH 连接、历史索引、文件目录、真实 Claude 回复与会话能力读取。Windows CI 另外检查编译和原生窗口 Loaded 事件，再输出 ZIP。

集成测试默认跳过。维护者可以设置 `MIRROR_SMOKE_HOST`、`MIRROR_SMOKE_PORT`、`MIRROR_SMOKE_USER`、`MIRROR_SMOKE_KEY`、`MIRROR_SMOKE_FINGERPRINT` 和 `MIRROR_SMOKE_RESOURCES` 运行只读连接检查；额外设置 `MIRROR_SMOKE_CHAT=1` 会创建一条测试会话，产生一次模型请求，随后关闭测试任务。私钥和真实主机配置不要提交到仓库。
