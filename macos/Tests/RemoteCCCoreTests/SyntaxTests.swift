import XCTest
@testable import RemoteCCCore

final class SyntaxTests: XCTestCase {
    private func tokens(_ code: String, _ language: String) -> [String] {
        let text = code as NSString
        return SyntaxHighlighter.spans(code, language: language).map { $0.kind.rawValue + ":" + text.substring(with: $0.range) }
    }

    func testSwiftKeywordsTypesDecoratorsStringsAndComments() {
        XCTAssertEqual(tokens("@MainActor struct A: View { let x = 42 // hi\n func f() -> String { \"q\\\"s\" } }", "swift"),
                       ["decorator:@MainActor", "keyword:struct", "builtin:A", "builtin:View", "keyword:let", "number:42", "comment:// hi",
                        "keyword:func", "function:f", "builtin:String", "string:\"q\\\"s\""])
    }

    func testRustLifetimesAreNotStringsButCharactersAre() {
        let result = tokens("fn f<'a>(s: &'a str) { let c = 'x'; println!(\"{}\"); }\n#[derive(Debug)]", "rs")
        XCTAssertTrue(result.contains("string:'x'"))
        XCTAssertFalse(result.contains { $0.hasPrefix("string:'a") })
        XCTAssertTrue(result.contains("function:println!"))
        XCTAssertEqual(result.last, "decorator:#[derive(Debug)]")
    }

    func testDataFormatsColourKeysAsProperties() {
        XCTAssertEqual(tokens("{\"key\": \"value\", \"ok\": true}", "json"), ["property:\"key\"", "string:\"value\"", "property:\"ok\"", "builtin:true"])
        XCTAssertEqual(tokens("name: demo\n  - item: 1 # note", "yaml"), ["property:name", "property:item", "number:1", "comment:# note"])
    }

    func testMarkupAndShell() {
        XCTAssertEqual(tokens("<a href=\"x\">&amp;</a>", "html"), ["keyword:a", "property:href", "string:\"x\"", "number:&amp;", "keyword:a"])
        XCTAssertEqual(tokens("echo $HOME a#b # c", "sh"), ["builtin:echo", "property:$HOME", "comment:# c"])
    }

    func testUnterminatedStringStopsAtLineEnd() {
        let result = tokens("let a = \"open\nlet b = 1", "swift")
        XCTAssertEqual(result, ["keyword:let", "string:\"open", "keyword:let", "number:1"])
    }

    func testLanguageDetectionAndLimits() {
        XCTAssertNotNil(SyntaxGrammar.forFile("/srv/app/Dockerfile"))
        XCTAssertNotNil(SyntaxGrammar.forFile("src/view.TSX"))
        XCTAssertNil(SyntaxGrammar.forFile("notes"))
        XCTAssertTrue(SyntaxHighlighter.spans("x", language: "unknown-language").isEmpty)
        XCTAssertTrue(SyntaxHighlighter.spans(String(repeating: "a", count: SyntaxHighlighter.limit + 1), language: "swift").isEmpty)
    }
}
