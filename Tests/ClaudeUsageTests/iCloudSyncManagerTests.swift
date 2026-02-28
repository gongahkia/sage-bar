import XCTest
@testable import ClaudeUsage

final class iCloudSyncManagerTests: XCTestCase {
    private let mgr = iCloudSyncManager.shared
    private let accountId = UUID()

    private func snap(_ tokens: Int, at date: Date) -> UsageSnapshot {
        UsageSnapshot(accountId: accountId, timestamp: date, inputTokens: tokens, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: 0, modelBreakdown: [])
    }

    func testNearIdenticalTimestampsDoNotDedupWithDeterministicKey() {
        let t = Date()
        let local = [snap(100, at: t)]
        let remote = [snap(200, at: t.addingTimeInterval(0.5))] // within 1s
        let merged = mgr.merge(local: local, remote: remote)
        XCTAssertEqual(merged.count, 2, "different timestamps should remain distinct events")
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

    func testExactMergeKeyCollisionPrefersHigherTokenSnapshot() {
        let t = Date()
        let local = [snap(100, at: t)]
        let remote = [snap(250, at: t)] // same deterministic key
        let merged = mgr.merge(local: local, remote: remote)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].inputTokens, 250)
    }

    func testNoOpOnEmptyRemote() {
        let t = Date()
        let local = [snap(100, at: t)]
        let merged = mgr.merge(local: local, remote: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].inputTokens, 100)
    }

    // MARK: - Task 60: remote newer modificationDate → appears in merged result

    func testRemoteNewerTimestampAppearsInMergedResult() {
        let t = Date()
        let local = [snap(100, at: t)]
        let remote = [snap(50, at: t.addingTimeInterval(5))] // 5s newer, distinct entry
        let merged = mgr.merge(local: local, remote: remote)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.timestamp > local[0].timestamp }, "newer remote snapshot must be present")
    }

    // MARK: - Task 61: sync with iCloud unavailable (NWPath analog) → no crash, local unchanged

    func testSyncNowUnavailableICloudDoesNotModifyLocalData() async {
        let pre = [snap(77, at: Date())]
        CacheManager.shared.save(pre)
        await mgr.syncNow() // iCloudSync.enabled=false in test env → early return, local untouched
        let post = CacheManager.shared.load().filter { $0.accountId == accountId }
        XCTAssertEqual(post.first?.inputTokens, 77, "local data must be unchanged when iCloud unavailable")
    }

    func testContentHashIsDeterministicAndChangesWithContent() {
        let a = Data("same".utf8)
        let b = Data("same".utf8)
        let c = Data("different".utf8)
        XCTAssertEqual(mgr.contentHash(for: a), mgr.contentHash(for: b))
        XCTAssertNotEqual(mgr.contentHash(for: a), mgr.contentHash(for: c))
    }
}
