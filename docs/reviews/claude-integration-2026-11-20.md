# Claude 对接审查 · 2026-11-20

范围：`src/task-worker.cts`、`src/session-input.cts`、`src/chat-service.cts`、`src/claude-launch.cts`、`src/remote-agent.cts`。

## 结论

对接方式是官方路径，不是拼命令行：远端 worker 用 `@anthropic-ai/claude-agent-sdk` 的 `query()`，流式输入，一个常驻进程服务一个会话。
权限、结构化提问、中断、模型与权限切换、续聊、后台任务都走 SDK 的控制接口，没有解析终端输出。

`npm run test:e2e` 用真实 worker、真实 SDK、真实 Claude Code CLI 跑通整条链路，只把 Anthropic API 换成本地脚本化服务，CI 每次都跑。

## 本次修掉的问题

| 问题 | 原因 | 改法 |
| --- | --- | --- |
| 回复中无法插队 | worker 在回复中拒绝一切新消息，客户端只能等回复结束 | 新增 `steer` 请求，消息以 SDK 的 `priority: 'next'` 交给 CLI。有工具调用时在下一步并入当前回复，否则紧接当前回复执行 |
| 停止后排队的消息仍会执行 | `query.interrupt()` 只中断当前回合，CLI 内已排队的消息随后照常运行 | 停止时用 `interrupt({ cancelQueued: true })`，并逐条 `cancelAsyncMessage` |
| 上下文用量要单独请求 | 客户端打开详情面板时才发一次控制请求 | 每回合结束和压缩后读一次 `getContextUsage`，随状态快照下发 |
| macOS 点停止没有即时反馈 | 客户端等远端确认后才改状态 | 本地立即进入“正在停止”，远端旧快照不再把它改回“正在回复” |

## 还在的问题

- **worker 借用 `ChatService`**。`ChatService` 是给 Electron 桌面端写的会话管理器，worker 只用其中的事件解析和审批部分，靠 `service.closing = true` 关掉它自带的队列。应把事件解析拆成独立模块，两边各自引用。这是纯重构，没有和本次行为改动放在一起。
- **额度保护对非订阅账号失效**。`account-quota.cts` 依赖 SDK 的实验接口 `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET`。用 API Key 登录时该接口不返回额度，保护按“未知即拒绝”处理，会话无法开始（e2e 测试中实测，测试因此替换了这一个读取）。Bedrock、Vertex 没有订阅额度，按代码推断结果相同，未实测。
- **额度轮询**。回复期间每 5 秒请求一次额度接口，多个会话靠文件租约协调。接口名已说明它随时可能变。是否保留这套保护需要产品决定，本次未改动。

## 验证方法

```sh
npm test            # 单元测试
npm run test:e2e    # 真实 CLI 对脚本化 API：并入当前回复、紧接执行、停止取消
swift test --package-path macos --filter SteeringTests
```
