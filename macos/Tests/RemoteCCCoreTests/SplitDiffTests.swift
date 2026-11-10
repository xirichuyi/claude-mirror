import XCTest
@testable import RemoteCCCore

final class SplitDiffTests: XCTestCase {
    private let patch = """
    diff --git a/src/auth.ts b/src/auth.ts
    --- a/src/auth.ts
    +++ b/src/auth.ts
    @@ -5,6 +5,9 @@ import { users } from './db';
     export async function login() {
    -  const { email } = request.body;
    +  const { email } = request.body ?? {};
    +  if (!email) {
    +  }
       try {
    @@ -20,3 +23,2 @@
     a
    -b
    -c
    +C
     d

    """

    func testRowsAlignWithRealLineNumbersAndFillers() {
        let diff = SplitDiff(patch)
        let summary = diff.rows.map { row -> String in
            func side(_ s: SplitDiff.Side) -> String { s.text == nil ? "~" : (s.number.map(String.init) ?? "@") }
            return "\(row.kind):\(side(row.left))/\(side(row.right))"
        }
        XCTAssertEqual(summary, ["hunk:@/@", "context:5/5", "modified:6/6", "added:~/7", "added:~/8", "context:7/9",
                                 "hunk:@/@", "context:20/23", "modified:21/24", "removed:22/~", "context:23/25"])
        XCTAssertEqual(diff.changes, [2..<5, 8..<10])
        XCTAssertEqual(diff.added, 4)
        XCTAssertEqual(diff.removed, 3)
        XCTAssertEqual(diff.rows[2].change, 0)
        XCTAssertNil(diff.rows[1].change)
    }

    func testModifiedLinesMarkOnlyTheChangedPart() {
        let diff = SplitDiff(patch)
        let modified = diff.rows[2]
        XCTAssertNil(modified.left.changed, "a pure insertion leaves the old line unmarked")
        let right = modified.right.text! as NSString
        XCTAssertEqual(right.substring(with: modified.right.changed!), " ?? {}")
        XCTAssertEqual(diff.rows[8].left.changed, NSRange(location: 0, length: 1))
    }

    func testEmptyAndHeaderOnlyPatches() {
        XCTAssertTrue(SplitDiff("").rows.isEmpty)
        XCTAssertTrue(SplitDiff("diff --git a/x b/x\nindex 1..2\n").rows.isEmpty)
    }
}
