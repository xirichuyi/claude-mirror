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
#endif
