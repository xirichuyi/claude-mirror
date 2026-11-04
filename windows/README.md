# claude-mirror — Windows 原生版

C# / WinUI 3 客户端，不使用 Electron 或 WebView。SSH.NET 负责连接，复用仓库现有的远端代理与 Claude 持久任务协议。

## 构建

Windows 用户运行发行附件 `Claude-Mirror-Setup-x64.exe`，按提示完成安装。从开始菜单打开 **Claude Mirror**。再次运行新版安装包即可更新；卸载入口在 Windows 设置的“已安装的应用”中。程序按当前用户安装，已有便携版的主机配置仍可使用。

Windows 10 1809+ / Windows 11，安装 .NET 9 SDK 和 Visual Studio 的 Windows 应用开发组件；构建机另需 Node.js 22。

```powershell
npm ci --ignore-scripts
node macos/scripts/prepare-server.cjs windows/Resources/server
dotnet test windows/ClaudeMirror.Tests -c Release
dotnet publish windows/ClaudeMirror.App -c Release -r win-x64 -p:Platform=x64 -o windows/dist/claude-mirror
```

构建机安装 Inno Setup 6 后执行 `./windows/build-installer.ps1 -Version 0.21.1`，生成自包含安装程序。也可保留完整发布目录以便携方式运行。本机用户无需安装 .NET、Node.js 或 Claude；远端需要 Linux/macOS、SSH、Node.js 18.14+ 及已认证的 Claude Code。

## 已接入

- 多主机命名，地址/端口/用户名，密码或私钥文件认证；密码仅保存在当前连接过程内存中。
- 首次确认主机指纹，指纹变更拒绝连接；SSH keepalive。
- 项目分组、分页同步历史索引、选中后读取消息。
- 新会话、历史续聊、远端持久任务、停止、工具权限确认与 AskUserQuestion 回答。
- 远端模型/命令列表；命令填入输入框，发送后由远端处理。
- 远端目录浏览，文本/图片预览和下载，选择文件/拖放上传；附件按内容哈希存入远端缓存，相同内容复用路径。
- 会话 ID 和远端任务 ID 保存在 LocalAppData/claude-mirror，可在重连选择历史会话时重新订阅。

## 当前边界

聊天和 Markdown 文件共用原生渲染器，支持标题、引用、表格、列表、任务标记、链接、行内代码和带语言名的围栏代码块。打开“远端文件”，选择文本文件即可在聊天右侧打开标签。使用“编辑”和 Ctrl+S 保存；保存遇到版本冲突时保留草稿。完整预览和编辑上限为 1 MB，窄窗口可用“返回对话”切换。

复杂命令的专用交互卡片、文件删除、自动重连、SSH config/ProxyJump/agent、反向访问、可视化 usage 和应用内自动更新尚未移植。私钥需要手动选择，不自动读取 macOS 配置。目录切换请新建会话，运行中的任务仍使用原目录。

原生 Windows 窗口交互须在 Windows 实机验收；macOS 只能验证共享 C# 核心和远端协议。CI 提供 Windows 编译、测试和自包含 x64 ZIP 工件。安装程序和客户端当前均未签名。

## 验证

核心单元测试覆盖状态增量、乱序保护、Shell 参数引用和本地状态持久化。已通过 `axi` 实测 SSH 连接、历史索引、文件目录、真实 Claude 回复与会话能力读取。Windows CI 另外检查编译和原生窗口 Loaded 事件，再输出 ZIP。

集成测试默认跳过。维护者可以设置 `MIRROR_SMOKE_HOST`、`MIRROR_SMOKE_PORT`、`MIRROR_SMOKE_USER`、`MIRROR_SMOKE_KEY`、`MIRROR_SMOKE_FINGERPRINT` 和 `MIRROR_SMOKE_RESOURCES` 运行只读连接检查；额外设置 `MIRROR_SMOKE_CHAT=1` 会创建一条测试会话，产生一次模型请求，随后关闭测试任务。私钥和真实主机配置不要提交到仓库。
