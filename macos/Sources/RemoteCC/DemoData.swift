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
#endif
