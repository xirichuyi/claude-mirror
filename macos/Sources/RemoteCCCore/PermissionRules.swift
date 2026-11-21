import Foundation

/// Plain-language lines for the SDK's suggested permission updates (`PermissionUpdate`), so the
/// confirmation card says what applying them does instead of showing their JSON.
public struct PermissionRuleLine: Hashable, Sendable {
    /// What the update does, e.g. "自动允许 Bash(npm test:*)".
    public var action: String
    /// Where it is saved, e.g. "此项目的本地设置".
    public var scope: String
    /// Whether it widens what runs without asking (allow rules, bypass mode, new directories).
    public var widens: Bool
}

public enum PermissionRules {
    static let scopes = ["session": "本次运行", "localSettings": "此项目的本地设置", "projectSettings": "此项目的共享设置",
                         "userSettings": "远端用户的所有项目", "cliArg": "本次启动参数"]
    static let modes = ["default": "默认", "acceptEdits": "自动接受编辑", "bypassPermissions": "跳过所有确认",
                        "plan": "计划模式", "dontAsk": "拒绝未授权操作"]

    public static func lines(_ suggestions: JSON?) -> [PermissionRuleLine] {
        (suggestions?.array ?? []).map(line)
    }

    static func line(_ update: JSON) -> PermissionRuleLine {
        let destination = update["destination"]?.string ?? ""
        let scope = scopes[destination] ?? destination
        let rules = (update["rules"]?.array ?? []).map { rule -> String in
            let tool = rule["toolName"]?.string ?? "工具"
            guard let content = rule["ruleContent"]?.string, !content.isEmpty else { return tool }
            return "\(tool)(\(content))"
        }.joined(separator: "、")
        let directories = (update["directories"]?.array ?? []).compactMap(\.string).joined(separator: "、")
        let behavior = update["behavior"]?.string
        let verb = behavior == "deny" ? "始终拒绝" : behavior == "ask" ? "始终询问" : "自动允许"
        switch update["type"]?.string {
        case "addRules": return PermissionRuleLine(action: "\(verb) \(rules)", scope: scope, widens: behavior == "allow")
        case "replaceRules": return PermissionRuleLine(action: "改为\(verb) \(rules)", scope: scope, widens: behavior == "allow")
        case "removeRules": return PermissionRuleLine(action: "移除规则 \(rules)", scope: scope, widens: behavior == "deny" || behavior == "ask")
        case "setMode":
            let mode = update["mode"]?.string ?? ""
            return PermissionRuleLine(action: "权限模式切换为「\(modes[mode] ?? mode)」", scope: scope,
                                      widens: ["acceptEdits", "bypassPermissions"].contains(mode))
        case "addDirectories": return PermissionRuleLine(action: "允许访问目录 \(directories)", scope: scope, widens: true)
        case "removeDirectories": return PermissionRuleLine(action: "移除目录 \(directories)", scope: scope, widens: false)
        default: return PermissionRuleLine(action: update.text(pretty: false), scope: scope, widens: true)
        }
    }
}

/// AskUserQuestion answers: options the user picked plus anything typed, in the SDK's
/// comma-joined form. Kept as a list so labels that contain commas still toggle correctly.
public struct QuestionAnswer: Hashable, Sendable {
    public var picked: [String] = []
    public var typed = ""
    public init() {}

    public mutating func toggle(_ label: String, multiple: Bool) {
        if !multiple { picked = picked == [label] ? [] : [label]; return }
        if let index = picked.firstIndex(of: label) { picked.remove(at: index) } else { picked.append(label) }
    }

    public var text: String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return (picked + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }
}

/// What a request asks, as a short question about its effect ("运行这条命令？"), not about the
/// mechanism ("Claude 请求使用 Bash"). The tool name stays visible in the detail line.
public enum PermissionPrompt {
    public static func headline(name: String?, input: JSON?) -> String {
        let file = (input?["file_path"]?.string ?? input?["notebook_path"]?.string).map { ($0 as NSString).lastPathComponent }
        switch name {
        case "Bash": return "运行这条命令？"
        case "Edit", "MultiEdit", "NotebookEdit": return "修改 \(file ?? "文件")？"
        case "Write": return "写入 \(file ?? "文件")？"
        case "Read": return "读取 \(file ?? "文件")？"
        case "Glob", "Grep", "LS": return "在项目中查找？"
        case "WebFetch":
            let host = input?["url"]?.string.flatMap { URL(string: $0)?.host }
            return "访问 \(host ?? "网页")？"
        case "WebSearch": return "搜索网页？"
        case "Task", "Agent": return "启动子代理？"
        case "ExitPlanMode": return "按这个计划开始执行？"
        case let name? where name.hasPrefix("mcp__"):
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            return parts.count >= 3 ? "使用 \(parts[1]) 的 \(parts[2...].joined(separator: "_"))？" : "使用 \(name)？"
        case let name?: return "使用 \(name)？"
        case nil: return "允许这项操作？"
        }
    }

    /// The remote's own sentence about the request, unless it only repeats the tool name.
    public static func detail(title: String?, description: String?) -> String? {
        for text in [description, title] {
            let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, !value.hasPrefix("Claude 请求使用") { return value }
        }
        return nil
    }
}
