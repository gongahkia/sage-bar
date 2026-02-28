import XCTest
@testable import ClaudeUsage

final class CacheManagerTests: XCTestCase {
    private var cm: CacheManager!
    private var fixtureDir: URL!
    private let accountId = UUID()

    override func setUp() {
        super.setUp()
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-cache-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        cm = CacheManager(baseURL: fixtureDir)
        cm.save([]) // reset cache to empty before each test
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fixtureDir)
        cm = nil
        super.tearDown()
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

    // MARK: - Task 62: shared AppGroup container path JSON round-trip

    func testSharedContainerPathJSONRoundTrip() throws {
        let s = snap(7.77)
        cm.save([s])
        let url = fixtureDir.appendingPathComponent("usage_cache.json")
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let payload = try dec.decode(UsageCachePayload.self, from: data)
        XCTAssertEqual(payload.schemaVersion, CacheSchema.currentVersion)
        XCTAssertTrue(payload.snapshots.contains { abs($0.totalCostUSD - 7.77) < 0.001 && $0.accountId == accountId })
    }

    // MARK: - Task 64: two concurrent DispatchQueue.async appends → valid JSON via JSONDecoder

    func testTwoConcurrentAsyncAppendsProduceValidJSON() {
        let g = DispatchGroup()
        g.enter(); g.enter()
        DispatchQueue.global().async { self.cm.append(self.snap(1.11)); g.leave() }
        DispatchQueue.global().async { self.cm.append(self.snap(2.22)); g.leave() }
        let exp = expectation(description: "both appends dispatched")
        g.notify(queue: .global()) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 3)
        let url = fixtureDir.appendingPathComponent("usage_cache.json")
        guard let data = try? Data(contentsOf: url) else { XCTFail("cache file missing"); return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try dec.decode(UsageCachePayload.self, from: data), "concurrent appends must not corrupt JSON")
    }

    func testSaveAndLoadAnthropicCursorPerAccount() {
        let cursor = AnthropicIngestionCursor(lastStartTime: "2026-02-28T00:00:00Z", lastModel: "claude-sonnet-4-6")
        cm.saveAnthropicCursor(cursor, forAccount: accountId)
        let exp = expectation(description: "cursor write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let loaded = cm.loadAnthropicCursor(forAccount: accountId)
        XCTAssertEqual(loaded?.lastStartTime, cursor.lastStartTime)
        XCTAssertEqual(loaded?.lastModel, cursor.lastModel)
    }

    func testUpsertAnthropicSnapshotsReplacesDeterministicKeyMatch() {
        let ts = Date()
        let initial = UsageSnapshot(
            accountId: accountId,
            timestamp: ts,
            inputTokens: 100,
            outputTokens: 40,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 1.0,
            modelBreakdown: [ModelUsage(modelId: "claude-sonnet-4-6", inputTokens: 100, outputTokens: 40, costUSD: 1.0)],
            costConfidence: .billingGrade
        )
        let replacement = UsageSnapshot(
            accountId: accountId,
            timestamp: ts,
            inputTokens: 120,
            outputTokens: 50,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 2.0,
            modelBreakdown: [ModelUsage(modelId: "claude-sonnet-4-6", inputTokens: 120, outputTokens: 50, costUSD: 2.0)],
            costConfidence: .billingGrade
        )
        cm.save([initial])
        cm.upsertAnthropicSnapshots([replacement], forAccount: accountId)
        let exp = expectation(description: "upsert")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let loaded = cm.load().filter { $0.accountId == accountId && $0.timestamp == ts }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.totalCostUSD, 2.0, accuracy: 0.001)
    }

    func testTodayAggregateNormalizesCumulativeSnapshotsToLatestOnly() {
        let now = Date()
        let early = UsageSnapshot(
            accountId: accountId,
            timestamp: now.addingTimeInterval(-600),
            inputTokens: 100,
            outputTokens: 20,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 0,
            modelBreakdown: [ModelUsage(modelId: "claude-code-local", inputTokens: 100, outputTokens: 20, costUSD: 0)],
            costConfidence: .estimated
        )
        let latest = UsageSnapshot(
            accountId: accountId,
            timestamp: now,
            inputTokens: 150,
            outputTokens: 30,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 0,
            modelBreakdown: [ModelUsage(modelId: "claude-code-local", inputTokens: 150, outputTokens: 30, costUSD: 0)],
            costConfidence: .estimated
        )
        cm.save([early, latest])
        let agg = cm.todayAggregate(forAccount: accountId)
        XCTAssertEqual(agg.totalInputTokens, 150)
        XCTAssertEqual(agg.totalOutputTokens, 30)
    }

    func testLoadDeduplicatesDeterministicEventKeyAndPrefersBillingGrade() {
        let ts = Date()
        let estimated = UsageSnapshot(
            accountId: accountId,
            timestamp: ts,
            inputTokens: 10,
            outputTokens: 2,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 0.15,
            modelBreakdown: [ModelUsage(modelId: "claude-sonnet-4-6", inputTokens: 10, outputTokens: 2, costUSD: 0.15)],
            costConfidence: .estimated
        )
        let billing = UsageSnapshot(
            accountId: accountId,
            timestamp: ts,
            inputTokens: 12,
            outputTokens: 3,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 0.20,
            modelBreakdown: [ModelUsage(modelId: "claude-sonnet-4-6", inputTokens: 12, outputTokens: 3, costUSD: 0.20)],
            costConfidence: .billingGrade
        )

        cm.save([estimated, billing])
        let loaded = cm.load().filter { $0.accountId == accountId && $0.timestamp == ts }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.costConfidence, .billingGrade)
        XCTAssertEqual(loaded.first?.inputTokens, 12)
    }

    func testLegacyUsageArrayMigratesToVersionedPayloadOnRead() throws {
        let legacy = [snap(3.14)]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let legacyData = try enc.encode(legacy)
        let url = fixtureDir.appendingPathComponent("usage_cache.json")
        try legacyData.write(to: url, options: .atomic)

        let loaded = cm.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.totalCostUSD, 3.14, accuracy: 0.001)

        let migratedData = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let payload = try dec.decode(UsageCachePayload.self, from: migratedData)
        XCTAssertEqual(payload.schemaVersion, CacheSchema.currentVersion)
        XCTAssertEqual(payload.snapshots.count, 1)
    }

    func testLegacyForecastArrayMigratesToVersionedPayloadOnRead() throws {
        let forecast = ForecastSnapshot(
            accountId: accountId,
            generatedAt: Date(),
            projectedEODCostUSD: 1.0,
            projectedEOWCostUSD: 2.0,
            projectedEOMCostUSD: 3.0,
            burnRatePerHour: 0.25
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let legacyData = try enc.encode([forecast])
        let url = fixtureDir.appendingPathComponent("forecast_cache.json")
        try legacyData.write(to: url, options: .atomic)

        let loaded = cm.latestForecast(forAccount: accountId)
        XCTAssertEqual(loaded?.projectedEOMCostUSD, 3.0, accuracy: 0.001)

        let migratedData = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let payload = try dec.decode(ForecastCachePayload.self, from: migratedData)
        XCTAssertEqual(payload.schemaVersion, CacheSchema.currentVersion)
        XCTAssertEqual(payload.forecasts.count, 1)
    }
}
