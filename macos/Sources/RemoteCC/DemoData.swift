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

    private static func decode<T: Decodable>(_ value: [String: Any]) -> T {
        try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private static let root = "/workspace/web-app"
    private static func entry(_ relative: String, directory: Bool = false, size: Int = 1200) -> FileEntry {
        decode(["path": root + "/" + relative, "name": (relative as NSString).lastPathComponent, "size": size, "directory": directory])
    }

    static let authSource = """
    import { Request, Response } from 'express';
    import { verifyPassword } from './crypto';
    import { users } from './db';

    // Rejects missing credentials before touching the database.
    export async function login(request: Request, response: Response) {
      const { email, password } = request.body ?? {};
      if (!email || !password) {
        return response.status(400).json({ error: 'Missing credentials' });
      }
      try {
        const user = await users.findByEmail(email);
        if (!user || !(await verifyPassword(password, user.hash))) {
          return response.status(401).json({ error: 'Invalid email or password' });
        }
        return response.json({ id: user.id, name: user.name });
      } catch (error) {
        console.error('login failed', error);
        return response.status(500).json({ error: 'Internal error' });
      }
    }
    """

    /// The file panel scene: a tree with Git states, two open files and a diff.
    @MainActor static func seed(_ workspace: Workspace) {
        let rows: [(entry: FileEntry, depth: Int, expanded: Bool, git: String?)] = [
            (entry("src", directory: true), 0, true, nil),
            (entry("src/routes", directory: true), 1, false, nil),
            (entry("src/auth.ts"), 1, false, "M"),
            (entry("src/crypto.ts"), 1, false, nil),
            (entry("src/server.ts"), 1, false, nil),
            (entry("test", directory: true), 0, true, nil),
            (entry("test/auth.test.ts"), 1, false, "A"),
            (entry(".env.example"), 0, false, nil),
            (entry("Dockerfile"), 0, false, nil),
            (entry("package.json"), 0, false, nil),
            (entry("package-lock.json"), 0, false, nil),
            (entry("README.md"), 0, false, "M"),
            (entry("tsconfig.json"), 0, false, nil),
        ]
        let auth: FilePreview = decode(["path": root + "/src/auth.ts", "name": "auth.ts", "size": authSource.utf8.count, "kind": "text", "text": authSource, "revision": "demo"])
        let readme: FilePreview = decode(["path": root + "/README.md", "name": "README.md", "size": 420, "kind": "text", "text": "# web-app\n\nLogin service.\n", "revision": "demo"])
        let diff = """
        diff --git a/src/auth.ts b/src/auth.ts
        @@ -5,6 +5,9 @@ import { users } from './db';
         export async function login(request: Request, response: Response) {
        -  const { email, password } = request.body;
        +  const { email, password } = request.body ?? {};
        +  if (!email || !password) {
        +    return response.status(400).json({ error: 'Missing credentials' });
        +  }
           try {
        """
        let git: GitStatus = decode(["repository": true, "branch": "main", "files": [
            ["status": " M", "path": root + "/src/auth.ts", "relative": "src/auth.ts"],
            ["status": "A ", "path": root + "/test/auth.test.ts", "relative": "test/auth.test.ts"],
            ["status": " M", "path": root + "/README.md", "relative": "README.md"],
        ]])
        workspace.seedPreview(root: root, rows: rows, files: [auth, readme], diff: (root + "/src/auth.ts", diff), active: auth.path, git: git)
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
        let section = { (index: Int) in "## \(index). 改动说明\n\n这一部分覆盖了 **接口校验**、*错误码统一* 和令牌刷新流程，`src/auth/session.ts` 的改动最大。下面的段落用于拉长回复，方便观察流式输出时的跟随滚动是否连续。\n\n- 缺少凭据时返回 `400`\n- 验证失败时返回 `401`\n- 服务异常时返回 `500`，不暴露内部错误\n\n| 接口 | 方法 | 新行为 |\n| --- | --- | --- |\n| `/api/login` | POST | 返回结构化 JSON 错误 |\n| `/api/refresh` | POST | 14 天滑动过期 |\n\n" }
        return "# 登录模块重构总结\n\n" + (1...4).map(section).joined() + "```typescript\n" + code + "\n```\n\n" + (5...8).map(section).joined() + "> 上线前请先在预发环境验证迁移脚本。\n"
    }()

    /// Sends one snapshot every `interval` seconds, `step` characters at a time, then ends the turn.
    static func start(_ engine: ChatEngine, session id: String, step: Int = 24, interval: TimeInterval = 0.04, finished: @escaping () -> Void = {}) {
        let characters = Array(reply)
        var sent = 0, version = 0
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                sent = min(characters.count, sent + step); version += 1
                let done = sent == characters.count
                let message = ChatMessage(id: messageId, role: "assistant", blocks: [Block(type: "text", text: String(characters[..<sent]))])
                guard let encoded = try? JSONEncoder().encode(message), let json = try? JSONDecoder().decode(JSON.self, from: encoded) else { return }
                try? engine.applyDemoSnapshot(id, state: ["version": .number(Double(version)), "status": .string(done ? "idle" : "working"), "message": json])
                if done { timer.invalidate(); finished() }
            }
        }
    }
}
#endif
