# claude-mirror — Windows 原生版

C# / WinUI 3 客户端，不使用 Electron 或 WebView。SSH.NET 负责连接，复用仓库现有的远端代理与 Claude 持久任务协议。

## 构建

Windows 10 1809+ / Windows 11，安装 .NET 9 SDK 和 Visual Studio 的 Windows 应用开发组件；构建机另需 Node.js 22。

```powershell
npm ci --ignore-scripts
node macos/scripts/prepare-server.cjs windows/Resources/server
dotnet test windows/ClaudeMirror.Tests -c Release
dotnet publish windows/ClaudeMirror.App -c Release -r win-x64 -p:Platform=x64 -o windows/dist/claude-mirror
```

运行发布目录中的 `claude-mirror.exe`。发布目录必须整体保留；打包为 ZIP 后解压运行。本机用户不需要 Node.js 或 Claude，远端需要 Linux/macOS、SSH、Node.js 18.14+ 及已认证的 Claude Code。

## 已接入

- 多主机命名，地址/端口/用户名，密码或私钥文件认证；密码仅保存在当前连接过程内存中。
- 首次确认主机指纹，指纹变更拒绝连接；SSH keepalive。
- 项目分组、分页同步历史索引、选中后读取消息。
- 新会话、历史续聊、远端持久任务、停止、工具权限确认。
- 远端模型/命令列表；命令填入输入框，发送后由远端处理。
- 远端目录浏览，文本/图片预览和下载，选择文件/拖放上传。
- 会话 ID 和远端任务 ID 保存在 LocalAppData/claude-mirror，可在重连选择历史会话时重新订阅。

## 当前边界

这是独立的 Windows 原生客户端首版，并非 macOS 版全部功能已经移植。当前消息以原生文本控件显示，Markdown 富文本、复杂命令的专用交互卡片、文件编辑/删除、自动重连、SSH config/ProxyJump/agent、反向访问、可视化 usage、自动更新检查尚未移植。私钥需要手动选择，不自动读取 macOS 配置。目录切换请新建会话，运行中的任务仍使用原目录。

原生 Windows 窗口交互须在 Windows 实机验收；macOS 只能验证共享 C# 核心和远端协议。CI 提供 Windows 编译、测试和自包含 x64 ZIP 工件。当前未签名、未提供安装向导，不会覆盖已有 macOS 发布包。
