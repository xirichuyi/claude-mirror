import XCTest
@testable import RemoteCCCore

final class PermissionRulesTests: XCTestCase {
    func testSuggestionsReadAsPlainLanguage() throws {
        let suggestions = try JSONDecoder().decode(JSON.self, from: Data("""
        [{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"},
         {"type":"setMode","mode":"acceptEdits","destination":"session"},
         {"type":"addDirectories","directories":["/srv/data"],"destination":"session"},
         {"type":"removeRules","rules":[{"toolName":"WebFetch"}],"behavior":"deny","destination":"userSettings"}]
        """.utf8))
        let lines = PermissionRules.lines(suggestions)
        XCTAssertEqual(lines.map(\.action), ["自动允许 Bash(npm test:*)", "权限模式切换为「自动接受编辑」", "允许访问目录 /srv/data", "移除规则 WebFetch"])
        XCTAssertEqual(lines.map(\.scope), ["此项目的本地设置", "本次运行", "本次运行", "远端用户的所有项目"])
        XCTAssertEqual(lines.map(\.widens), [true, true, true, true])
        XCTAssertTrue(PermissionRules.lines(nil).isEmpty)
    }

    func testDontAskDoesNotPromiseAutomaticApproval() throws {
        let suggestions = try JSONDecoder().decode(JSON.self, from: Data(#"[{"type":"setMode","mode":"dontAsk","destination":"session"}]"#.utf8))
        let line = try XCTUnwrap(PermissionRules.lines(suggestions).first)
        XCTAssertEqual(line.action, "权限模式切换为「拒绝未授权操作」")
        XCTAssertFalse(line.widens)
    }

    func testQuestionAnswerKeepsLabelsWithCommas() {
        var answer = QuestionAnswer()
        answer.toggle("Red, bright", multiple: true)
        answer.toggle("Blue", multiple: true)
        XCTAssertEqual(answer.picked, ["Red, bright", "Blue"])
        answer.toggle("Red, bright", multiple: true)
        XCTAssertEqual(answer.picked, ["Blue"])
        answer.typed = "  and green "
        XCTAssertEqual(answer.text, "Blue, and green")

        var single = QuestionAnswer()
        single.toggle("A", multiple: false)
        single.toggle("B", multiple: false)
        XCTAssertEqual(single.picked, ["B"])
        single.toggle("B", multiple: false)
        XCTAssertEqual(single.text, "")
    }
}

final class PermissionPromptTests: XCTestCase {
    func testHeadlinesAskAboutTheEffect() throws {
        func input(_ text: String) throws -> JSON { try JSONDecoder().decode(JSON.self, from: Data(text.utf8)) }
        XCTAssertEqual(PermissionPrompt.headline(name: "Bash", input: try input(#"{"command":"ls"}"#)), "运行这条命令？")
        XCTAssertEqual(PermissionPrompt.headline(name: "Edit", input: try input(#"{"file_path":"/a/b/App.swift"}"#)), "修改 App.swift？")
        XCTAssertEqual(PermissionPrompt.headline(name: "WebFetch", input: try input(#"{"url":"https://example.com/x"}"#)), "访问 example.com？")
        XCTAssertEqual(PermissionPrompt.headline(name: "mcp__github__create_issue", input: nil), "使用 github 的 create_issue？")
        XCTAssertEqual(PermissionPrompt.detail(title: "Claude 请求使用 Bash", description: " "), nil)
        XCTAssertEqual(PermissionPrompt.detail(title: "Claude 请求使用 Bash", description: "运行单元测试"), "运行单元测试")
    }
}
