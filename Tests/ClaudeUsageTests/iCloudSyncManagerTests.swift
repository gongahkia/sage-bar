import XCTest
@testable import ClaudeUsage

final class iCloudSyncManagerTests: XCTestCase {
    private let mgr = iCloudSyncManager.shared
    private let accountId = UUID()

    private func snap(_ tokens: Int, at date: Date) -> UsageSnapshot {
        UsageSnapshot(accountId: accountId, timestamp: date, inputTokens: tokens, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: 0, modelBreakdown: [])
    }

    func testDedupWithin1sPreferHigherTokens() {
        let t = Date()
        let local = [snap(100, at: t)]
        let remote = [snap(200, at: t.addingTimeInterval(0.5))] // within 1s
        let merged = mgr.merge(local: local, remote: remote)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].inputTokens, 200, "should prefer higher token count")
    }

    func testDedupDoesNotMergeSnapshotsMoreThan1sApart() {
        let t = Date()
        let local = [snap(100, at: t)]
        let remote = [snap(200, at: t.addingTimeInterval(2))] // > 1s apart
        let merged = mgr.merge(local: local, remote: remote)
        XCTAssertEqual(merged.count, 2)
    }

    func testIdenticalRecordsNotDuplicated() {
        let t = Date()
        let snap = self.snap(150, at: t)
        let merged = mgr.merge(local: [snap], remote: [snap])
        XCTAssertEqual(merged.count, 1)
    }

    func testNoOpOnEmptyRemote() {
        let t = Date()
        let local = [snap(100, at: t)]
        let merged = mgr.merge(local: local, remote: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].inputTokens, 100)
    }
}
