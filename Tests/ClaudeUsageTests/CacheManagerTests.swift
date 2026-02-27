import XCTest
@testable import ClaudeUsage

final class CacheManagerTests: XCTestCase {
    private let cm = CacheManager.shared
    private let accountId = UUID()

    override func setUp() {
        super.setUp()
        cm.save([]) // reset cache to empty before each test
    }

    private func snap(_ cost: Double, at date: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(accountId: accountId, timestamp: date, inputTokens: 10, outputTokens: 5,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: cost, modelBreakdown: [])
    }

    func testAppendAndRead() {
        let exp = expectation(description: "append")
        let s = snap(1.5)
        cm.append(s)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let loaded = self.cm.load().filter { $0.accountId == self.accountId }
            XCTAssertEqual(loaded.count, 1)
            XCTAssertEqual(loaded.first?.totalCostUSD, 1.5, accuracy: 0.001)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testPruning30DayBoundary() {
        let old = snap(9.9, at: Date().addingTimeInterval(-31 * 86400)) // 31 days ago
        let recent = snap(1.0, at: Date())
        cm.save([old])
        let exp = expectation(description: "prune")
        cm.append(recent) // triggers pruning
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let loaded = self.cm.load().filter { $0.accountId == self.accountId }
            XCTAssertFalse(loaded.contains { $0.totalCostUSD == 9.9 }, "old snapshot should be pruned")
            XCTAssertTrue(loaded.contains { $0.totalCostUSD == 1.0 }, "recent snapshot must be retained")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testConcurrentWrites() {
        let exp = expectation(description: "concurrent")
        exp.expectedFulfillmentCount = 10
        for i in 0..<10 {
            cm.append(snap(Double(i)))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 3)
        // verify no crash and at least 1 snapshot exists
        XCTAssertFalse(cm.load().isEmpty)
    }

    func testReadEmptyCacheReturnsEmpty() {
        XCTAssertTrue(cm.load().filter { $0.accountId == accountId }.isEmpty)
    }
}
