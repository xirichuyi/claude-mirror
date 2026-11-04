import XCTest
@testable import RemoteCCCore

final class QuotaResetTests: XCTestCase {
    func testTimestampFormatsAndTimezone() throws {
        let date = try XCTUnwrap(QuotaReset.date("2026-11-04T18:30:00.123456+00:00"))
        let whole = try XCTUnwrap(QuotaReset.date("2026-11-04T18:30:00Z"))
        XCTAssertEqual(date.timeIntervalSince(whole), 0.123456, accuracy: 0.002)
        XCTAssertTrue(QuotaReset.localTime(whole, timeZone: TimeZone(secondsFromGMT: 28800)!).contains("11月5日 02:30"))
        XCTAssertNil(QuotaReset.date(nil))
        XCTAssertNil(QuotaReset.date("unknown"))
    }

    func testCountdownDoesNotClaimQuotaResetBeforeServerRefresh() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(QuotaReset.countdown(until: now.addingTimeInterval(1), now: now), "1分钟后重置")
        XCTAssertEqual(QuotaReset.countdown(until: now.addingTimeInterval(3660), now: now), "1小时 1分钟后重置")
        XCTAssertEqual(QuotaReset.countdown(until: now.addingTimeInterval(90000), now: now), "1天 1小时后重置")
        XCTAssertEqual(QuotaReset.countdown(until: now, now: now), "已到重置时间，等待更新")
        XCTAssertEqual(QuotaReset.countdown(until: now.addingTimeInterval(-1), now: now), "已到重置时间，等待更新")
    }
}
