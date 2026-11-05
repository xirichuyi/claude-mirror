import XCTest
@testable import RemoteCCCore

final class SharedFileRequestsTests: XCTestCase {
    actor Counter {
        var starts = 0
        var cancellations = 0
        func run() async throws -> Int {
            starts += 1
            do { try await Task.sleep(nanoseconds: 300_000_000); return 7 }
            catch { cancellations += 1; throw error }
        }
    }

    func testCoalescingAndIndependentCancellation() async throws {
        let requests = SharedFileRequests<Int>(), counter = Counter()
        let first = Task { try await requests.value(for: "file") { try await counter.run() } }
        try await Task.sleep(nanoseconds: 30_000_000)
        let second = Task { try await requests.value(for: "file") { try await counter.run() } }
        try await Task.sleep(nanoseconds: 30_000_000)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled waiter returned data") } catch { }
        let value = try await second.value
        XCTAssertEqual(value, 7)
        let starts = await counter.starts, cancellations = await counter.cancellations
        XCTAssertEqual(starts, 1); XCTAssertEqual(cancellations, 0)
    }

    func testLastCancellationStopsWorkAndNextRequestCanRetry() async throws {
        let requests = SharedFileRequests<Int>(), counter = Counter()
        let task = Task { try await requests.value(for: "file") { try await counter.run() } }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled waiter returned data") } catch { }
        let value = try await requests.value(for: "file") { try await counter.run() }
        XCTAssertEqual(value, 7)
        let starts = await counter.starts, cancellations = await counter.cancellations
        XCTAssertEqual(starts, 2); XCTAssertEqual(cancellations, 1)
    }
}
