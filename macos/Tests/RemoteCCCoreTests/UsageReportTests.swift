import XCTest
@testable import RemoteCCCore

final class UsageReportTests: XCTestCase {
    func testUsagePreservesZeroAndResetTimezone() throws {
        let text = "You are currently using your subscription to power your Claude Code usage\nCurrent session: 0% used\nCurrent week (all models): 10% used · resets Nov 7, 1pm (America/Los_Angeles)\n\nWhat's contributing to your usage?\nLast 24h · 215 requests · 12 sessions\nLast 7d · 744 requests · 37 sessions"
        let report = try XCTUnwrap(UsageReport(text))
        XCTAssertEqual(report.windows.map(\.percent), [0, 10])
        XCTAssertNil(report.windows[0].reset)
        XCTAssertEqual(report.windows[1].reset, "Nov 7, 1pm (America/Los_Angeles)")
        XCTAssertEqual(report.activity.map(\.requests), ["215", "744"])
        XCTAssertEqual(report.raw, text)
    }
    func testFlattenedHistoryStillGetsVisualReport() throws {
        let report = try XCTUnwrap(UsageReport("Current session: 94% used · resets Nov 3, 2pm (UTC) Current week (all models): 10% used · resets Nov 7, 1pm (UTC) What's contributing to your usage? Last 24h · 217 requests · 13 sessions"))
        XCTAssertEqual(report.windows.count, 2)
        XCTAssertEqual(report.windows[0].percent, 94)
        XCTAssertEqual(report.activity.first?.sessions, "13")
    }
    func testOtherRepliesAndMalformedValuesRemainText() {
        XCTAssertNil(UsageReport("Current session: unknown% used Current week"))
        XCTAssertNil(UsageReport("Current session: 110% used Current week"))
        XCTAssertNil(UsageReport("A normal answer with 10% used"))
    }
}
