import XCTest
@testable import ClaudeUsage

final class iCloudSyncManagerTests: XCTestCase {
    private let mgr = iCloudSyncManager.shared
    private let accountId = UUID()

    private func snap(_ tokens: Int, at date: Date, modelId: String? = nil) -> UsageSnapshot {
        let breakdown: [ModelUsage]
        if let modelId {
            breakdown = [ModelUsage(modelId: modelId, inputTokens: tokens, outputTokens: 0, costUSD: 0)]
        } else {
            breakdown = []
        }
        return UsageSnapshot(accountId: accountId, timestamp: date, inputTokens: tokens, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: 0, modelBreakdown: breakdown)
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

    func testNearIdenticalTimestampDifferentModelsRemainDistinct() {
        let t = Date()
        let local = [snap(100, at: t, modelId: "claude-3-sonnet")]
        let remote = [snap(120, at: t.addingTimeInterval(0.2), modelId: "claude-3-haiku")]
        let merged = mgr.merge(local: local, remote: remote)
        XCTAssertEqual(merged.count, 2, "near-identical timestamps across different models must not collide")
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

    func testMergeKeyCollisionPrefersBillingGradeConfidence() {
        let t = Date()
        let estimated = UsageSnapshot(
            accountId: accountId,
            timestamp: t,
            inputTokens: 400,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 1.0,
            modelBreakdown: [ModelUsage(modelId: "claude-3-sonnet", inputTokens: 400, outputTokens: 0, costUSD: 1.0)],
            costConfidence: .estimated
        )
        let billing = UsageSnapshot(
            accountId: accountId,
            timestamp: t,
            inputTokens: 100,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 0.5,
            modelBreakdown: [ModelUsage(modelId: "claude-3-sonnet", inputTokens: 100, outputTokens: 0, costUSD: 0.5)],
            costConfidence: .billingGrade
        )
        let merged = mgr.merge(local: [estimated], remote: [billing])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.costConfidence, .billingGrade)
    }

    func testMergeKeyCollisionPrefersFreshSnapshotWhenConfidenceMatches() {
        let t = Date()
        let stale = UsageSnapshot(
            accountId: accountId,
            timestamp: t,
            inputTokens: 300,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 1.0,
            modelBreakdown: [ModelUsage(modelId: "claude-3-sonnet", inputTokens: 300, outputTokens: 0, costUSD: 1.0)],
            isStale: true,
            costConfidence: .billingGrade
        )
        let fresh = UsageSnapshot(
            accountId: accountId,
            timestamp: t,
            inputTokens: 200,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 1.0,
            modelBreakdown: [ModelUsage(modelId: "claude-3-sonnet", inputTokens: 200, outputTokens: 0, costUSD: 1.0)],
            isStale: false,
            costConfidence: .billingGrade
        )
        let merged = mgr.merge(local: [stale], remote: [fresh])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.isStale, false)
    }
}
