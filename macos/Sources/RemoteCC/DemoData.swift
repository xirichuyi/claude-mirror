#if DEBUG && canImport(SwiftUI)
import Foundation
import RemoteCCCore

/// Sanitized documentation fixtures. No SSH process can be started in this build.
final class DemoLauncher: RemoteLauncher, @unchecked Sendable {
    func spawn(_ config: ConnectionConfig, command: String) throws -> RemoteProcess {
        throw RemoteError("文档示例不连接服务器")
    }
}

enum DemoData {
    static let config = ConnectionConfig(host: "dev-server", directory: "/workspace/web-app", name: "开发服务器")
    static func sessions() -> [ChatSession] {
        var chat = ChatSession(config: config, name: "检查登录接口")
        chat.messages = [
            ChatMessage(role: "user", text: "请检查登录接口的错误处理，并补充测试。"),
            ChatMessage(role: "assistant", blocks: [
                Block(type: "tool", name: "Read", input: ["file_path": "/workspace/web-app/src/auth.ts"], status: "done"),
                Block(type: "tool", name: "Bash", input: ["command": "npm test", "description": "运行测试"], status: "done", output: "12 tests passed"),
                Block(type: "text", text: "已补充登录接口的错误处理。\n\n- 缺少凭据时返回 `400`\n- 验证失败时返回 `401`\n- 服务异常时返回 `500`，不暴露内部错误\n\n```typescript\nif (!email || !password) {\n  return response.status(400).json({ error: 'Missing credentials' });\n}\n```\n\n新增的边界测试已通过。")
            ])
        ]
        return [chat, ChatSession(config: config, name: "整理项目文档"), ChatSession(config: ConnectionConfig(host: "dev-server", directory: "/workspace/api-service"), name: "添加分页查询")]
    }
}

/// Demo-only transcript for layout checks: `MIRROR_SCENE=markdown` (or `markdown-files` with the file
/// panel open) shows a failed tool call, lists, a wide table, one-line code, a quote and a long code block.
extension DemoData {
    static func markdownSession() -> ChatSession {
        var session = ChatSession(config: config, name: "长回复排版示例")
        let failed = Block(type: "tool", name: "Bash", input: ["command": "npm run test -- --runInBand --coverage --testPathPattern='src/auth/.*' --reporters=default", "description": "运行认证模块的全部测试"], status: "error",
                           output: (1...12).map { "FAIL src/auth/session.test.ts > refresh token rotation > case \($0): expected status 401 but received 500 (requestId=3f6c1f0e-2b7a-4b55-9a54-0c1d9e2f7a\($0 + 10))" }.joined(separator: "\n"))
        let code = (["import { Router, Request, Response } from 'express';", "import { z } from 'zod';", "", "// 入参统一用同一份 schema 校验", "const schema = z.object({ email: z.string().email(), password: z.string().min(8), remember: z.boolean().optional(), device: z.string().max(64).optional() });", ""]
            + (1...45).flatMap { ["export async function handler\($0)(request: Request, response: Response) {", "  const parsed = schema.safeParse(request.body); // step \($0)", "  if (!parsed.success) return response.status(400).json({ error: 'Missing credentials', details: parsed.error.flatten().fieldErrors });", "  return response.json({ ok: true, index: \($0) });", "}"] }).joined(separator: "\n")
        let summary = """
        # 登录模块重构总结

        这一轮改动覆盖了 **接口校验**、*错误码统一* 和 ~~旧的会话存储~~ 新的令牌刷新流程，详见 [设计文档](https://example.com/docs/auth-design)。其中 `src/auth/session.ts` 的改动最大，入口是 `rotate(family, previous)`。

        1. 校验层：使用 `zod` 统一入参
           - 邮箱格式、密码长度
           - 设备指纹长度上限 `64`
        2. 错误码：`400` / `401` / `429` / `500`

        - [x] 入参校验
        - [x] 刷新令牌
        - [ ] 速率限制的集成测试

        | 接口 | 方法 | 旧行为 | 新行为 | 状态码 | 备注 |
        | --- | --- | --- | --- | --- | --- |
        | `/api/login` | POST | 缺少凭据时返回 HTML 错误页 | 返回结构化 JSON 错误 | 400 | 已覆盖测试 |
        | `/api/refresh` | POST | 刷新令牌永不过期 | 14 天滑动过期 | 401 | 需要数据库迁移 |
        | `/api/logout` | DELETE | 只清理 Cookie | 同时吊销服务端会话 | 204 | — |

        运行方式：

        ```bash
        npm run test -- --runInBand --coverage --testPathPattern='src/auth/.*\\.test\\.ts$' --reporters=default --reporters=jest-junit && npm run lint -- --max-warnings=0
        ```

        > 注意：刷新令牌的吊销是 **不可逆** 的。
        > 上线前请先在预发环境验证迁移脚本。
        """
        session.messages = [
            ChatMessage(role: "user", text: "请重构登录模块，跑一遍测试，然后给我一份总结。"),
            ChatMessage(role: "assistant", blocks: [Block(type: "thinking", text: "先跑测试确认现状，再整理改动。"), failed, Block(type: "text", text: summary)]),
            ChatMessage(role: "user", text: "把路由文件的完整代码贴出来。"),
            ChatMessage(role: "assistant", blocks: [Block(type: "text", text: "完整的路由文件如下，共 \(code.components(separatedBy: "\n").count) 行：\n\n```typescript\n\(code)\n```\n\n以上代码已通过 `npm test`。")])
        ]
        return session
    }
}

/// Demo-only streamed reply: `MIRROR_SCENE=stream` feeds a long Markdown answer through
/// `ChatEngine` at a realistic chunk rate, so streaming can be seen and measured without a server.
@MainActor
enum DemoStream {
    static let messageId = "demo-stream-reply"

    static func session() -> ChatSession {
        var session = ChatSession(config: DemoData.config, name: "流式回复示例")
        // Earlier turns give the transcript something to scroll and show what unchanged rows cost.
        let earlier = (0..<10).flatMap { _ in DemoData.sessions()[0].messages.map { message in var copy = message; copy.id = UUID().uuidString.lowercased(); return copy } }
        session.messages = earlier + [ChatMessage(role: "user", text: "请总结登录模块的重构，包含对照表和关键代码。"), ChatMessage(id: messageId, role: "assistant", blocks: [])]
        session.status = "working"
        session.remoteOwner = try? JSONDecoder().decode(RemoteOwner.self, from: Data(#"{"id":"demo-stream","version":0,"messageId":"\#(messageId)"}"#.utf8))
        return session
    }

    static let reply: String = {
        let code = (1...40).map { "export async function handler\($0)(request: Request, response: Response) {\n  const parsed = schema.safeParse(request.body);\n  if (!parsed.success) return response.status(400).json({ error: 'Missing credentials' });\n  return response.json({ ok: true, index: \($0) });\n}" }.joined(separator: "\n")
        let section = { (index: Int) in "## \(index). 改动说明\n\n这一部分覆盖了 **接口校验**、*错误码统一* 和令牌刷新流程，`src/auth/session.ts` 的改动最大。下面的段落用于拉长回复，方便观察流式输出时的跟随滚动是否连续。校验层统一使用同一份 schema，错误信息带上请求编号，方便在日志里对应到具体的一次调用；刷新令牌改为十四天滑动过期，重复使用同一个令牌会吊销整条链，避免泄露之后被长期利用。这一段故意写得比较长，窗口变窄或者打开右侧面板时它会重新换行，可以用来检查阅读位置是否保持不动。\n\n- 第 \(index) 节：缺少凭据时返回 `400`\n- 验证失败时返回 `401`\n- 服务异常时返回 `500`，不暴露内部错误\n\n| 接口 | 方法 | 新行为 |\n| --- | --- | --- |\n| `/api/login` | POST | 返回结构化 JSON 错误 |\n| `/api/refresh` | POST | 14 天滑动过期 |\n\n" }
        return "# 登录模块重构总结\n\n" + (1...4).map(section).joined() + "```typescript\n" + code + "\n```\n\n" + (5...8).map(section).joined() + "> 上线前请先在预发环境验证迁移脚本。\n"
    }()

    /// Sends one snapshot every `interval` seconds, `step` characters at a time, then ends the turn.
    static func start(_ engine: ChatEngine, session id: String, step: Int = 24, interval: TimeInterval = 0.04, finished: @escaping () -> Void = {}) {
        let characters = Array(reply)
        var sent = 0, version = 0
        // One message updated in place, like a real turn: only its text changes between snapshots.
        var message = ChatMessage(id: messageId, role: "assistant")
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                sent = min(characters.count, sent + step); version += 1
                let done = sent == characters.count
                message.blocks = [Block(type: "text", text: String(characters[..<sent]))]
                guard let encoded = try? JSONEncoder().encode(message), let json = try? JSONDecoder().decode(JSON.self, from: encoded) else { return }
                try? engine.applyDemoSnapshot(id, state: ["version": .number(Double(version)), "status": .string(done ? "idle" : "working"), "message": json])
                if done { timer.invalidate(); finished() }
            }
        }
    }
}
#endif
