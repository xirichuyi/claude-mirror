import XCTest
@testable import RemoteCCCore

final class ReviewCommentTests: XCTestCase {
    private let diff = SplitDiff("""
    @@ -1,3 +1,3 @@
     keep
    -old line
    +new line
    -gone
    """)

    func testRowsPickTheirNewSideOrTheDeletedLine() throws {
        let modified = try XCTUnwrap(diff.rows.first { $0.kind == .modified })
        let comment = try XCTUnwrap(ReviewComment(row: modified, path: "/p/a.ts", text: " 改名 \n"))
        XCTAssertEqual(comment.line, 2); XCTAssertFalse(comment.removed); XCTAssertEqual(comment.code, "new line"); XCTAssertEqual(comment.text, "改名")
        let deleted = try XCTUnwrap(diff.rows.first { $0.kind == .removed })
        let gone = try XCTUnwrap(ReviewComment(row: deleted, path: "/p/a.ts", text: "为什么删"))
        XCTAssertEqual(gone.line, 3); XCTAssertTrue(gone.removed)
        XCTAssertNil(ReviewComment(row: diff.rows[0], path: "/p/a.ts", text: "x"))
        XCTAssertNil(ReviewComment(row: modified, path: "/p/a.ts", text: "  "))
    }

    func testPromptListsCommentsInFileOrder() {
        let comments = [
            ReviewComment(path: "/p/b.ts", line: 1, code: "b()", text: "第二"),
            ReviewComment(path: "/p/a.ts", line: 9, removed: true, code: "  gone()", text: "第一\n两行"),
        ]
        XCTAssertEqual(ReviewComment.prompt(comments, root: "/p"), """
        请按下面的评论修改代码：

        1. `a.ts 删除前第 9 行`
           > gone()
           第一
           两行

        2. `b.ts:1`
           > b()
           第二
        """)
        XCTAssertEqual(ReviewComment.relative("/other/x", to: "/p"), "/other/x")
    }
}
