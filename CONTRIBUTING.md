# 参与开发

## 开始之前

- 先读[开发指南](docs/development.md)，按要改的平台准备环境。
- 较大的改动先开 Issue 讨论方案。
- 安全问题不要公开提交，见 [SECURITY.md](SECURITY.md)。

## 目录

| 目录 | 语言 | 测试命令 |
| --- | --- | --- |
| `src/`、`scripts/`、`test/` | TypeScript | `npm test` |
| `macos/` | Swift | `swift test --package-path macos` |
| `windows/` | C# | `dotnet test windows/ClaudeMirror.Tests -c Release` |
| `android/` | Kotlin | `cd android && ./gradlew test lint` |

服务端协议改动要同时检查三端客户端，协议说明在 [docs/agent-wire.md](docs/agent-wire.md)。

## 代码规范

- 跟随周边代码的风格，改动尽量小而集中。
- macOS 界面代码遵循 [macOS 界面代码规范](docs/macos-code-style.md)。
- 界面文字用简短中文，不写解释性小字。
- 不提交凭据、私钥、聊天数据或本机配置。
- 不直接编辑 `build/` 里的编译产物。

## 提交与 PR

- 一个 PR 只做一件事，标题写清楚改了什么。
- 提交前运行对应目录的测试；CI 会在 Linux、macOS 和 Windows 上构建与测试。
- 界面改动附截图。
- 用户可见的变化写进下一版的 `docs/releases/vX.Y.Z.md`。
