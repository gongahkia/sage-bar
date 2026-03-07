import XCTest
@testable import SageBar

final class DataModelTests: XCTestCase {
    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private let fixedID = UUID()
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - CostConfidence
    func testCostConfidenceRawValues() {
        XCTAssertEqual(CostConfidence.billingGrade.rawValue, "billingGrade")
        XCTAssertEqual(CostConfidence.estimated.rawValue, "estimated")
    }

    // MARK: - UsageSnapshot defaults
    func testUsageSnapshotDefaultCostConfidenceIsBillingGrade() {
        let snap = UsageSnapshot(
            accountId: fixedID, timestamp: fixedDate,
            inputTokens: 10, outputTokens: 5,
            cacheCreationTokens: 0, cacheReadTokens: 0,
            totalCostUSD: 1.0, modelBreakdown: [])
        XCTAssertEqual(snap.costConfidence, .billingGrade)
        XCTAssertFalse(snap.isStale)
    }

    // MARK: - UsageSnapshot stale round-trip
    func testUsageSnapshotStaleRoundTrip() throws {
        let snap = UsageSnapshot(
            accountId: fixedID, timestamp: fixedDate,
            inputTokens: 100, outputTokens: 50,
            cacheCreationTokens: 2, cacheReadTokens: 3,
            totalCostUSD: 4.5, modelBreakdown: [],
            isStale: true, costConfidence: .estimated)
        let data = try makeEncoder().encode(snap)
        let decoded = try makeDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
        XCTAssertTrue(decoded.isStale)
        XCTAssertEqual(decoded.costConfidence, .estimated)
    }

    // MARK: - ModelUsage cacheTokens legacy
    func testModelUsageCacheTokensDefaultsToZeroForLegacyJSON() throws {
        let json = """
        {"modelId":"claude-sonnet-4-6","inputTokens":10,"outputTokens":5,"costUSD":0.5}
        """
        let usage = try makeDecoder().decode(ModelUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.cacheTokens, 0)
    }

    func testModelUsageCacheTokensPreservedWhenPresent() throws {
        let json = """
        {"modelId":"claude-sonnet-4-6","inputTokens":10,"outputTokens":5,"cacheTokens":42,"costUSD":0.5}
        """
        let usage = try makeDecoder().decode(ModelUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.cacheTokens, 42)
    }

    // MARK: - DailyAggregate computed properties
    func testDailyAggregateComputedProperties() {
        let s1 = UsageSnapshot(
            accountId: fixedID, timestamp: fixedDate,
            inputTokens: 100, outputTokens: 50,
            cacheCreationTokens: 0, cacheReadTokens: 0,
            totalCostUSD: 1.5, modelBreakdown: [])
        let s2 = UsageSnapshot(
            accountId: fixedID, timestamp: fixedDate,
            inputTokens: 200, outputTokens: 80,
            cacheCreationTokens: 0, cacheReadTokens: 0,
            totalCostUSD: 2.5, modelBreakdown: [])
        let agg = DailyAggregate(
            date: DateComponents(year: 2026, month: 3, day: 7),
            snapshots: [s1, s2])
        XCTAssertEqual(agg.totalInputTokens, 300)
        XCTAssertEqual(agg.totalOutputTokens, 130)
        XCTAssertEqual(agg.totalCostUSD, 4.0, accuracy: 0.001)
    }

    func testDailyAggregateEmptySnapshots() {
        let agg = DailyAggregate(
            date: DateComponents(year: 2026, month: 1, day: 1),
            snapshots: [])
        XCTAssertEqual(agg.totalInputTokens, 0)
        XCTAssertEqual(agg.totalOutputTokens, 0)
        XCTAssertEqual(agg.totalCostUSD, 0.0, accuracy: 0.001)
    }

    // MARK: - CacheSchema
    func testCacheSchemaCurrentVersion() {
        XCTAssertEqual(CacheSchema.currentVersion, 2)
    }

    // MARK: - UsageCachePayload round-trip
    func testUsageCachePayloadRoundTrip() throws {
        let snap = UsageSnapshot(
            accountId: fixedID, timestamp: fixedDate,
            inputTokens: 10, outputTokens: 5,
            cacheCreationTokens: 1, cacheReadTokens: 2,
            totalCostUSD: 0.3,
            modelBreakdown: [
                ModelUsage(modelId: "claude-sonnet-4-6", inputTokens: 10, outputTokens: 5, costUSD: 0.3)
            ])
        let payload = UsageCachePayload(snapshots: [snap])
        XCTAssertEqual(payload.schemaVersion, CacheSchema.currentVersion)
        let data = try makeEncoder().encode(payload)
        let decoded = try makeDecoder().decode(UsageCachePayload.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, payload.schemaVersion)
        XCTAssertEqual(decoded.snapshots.count, 1)
        XCTAssertEqual(decoded.snapshots.first, snap)
    }

    // MARK: - ForecastCachePayload round-trip
    func testForecastCachePayloadRoundTrip() throws {
        let forecast = ForecastSnapshot(
            accountId: fixedID, generatedAt: fixedDate,
            projectedEODCostUSD: 10.0, projectedEOWCostUSD: 50.0,
            projectedEOMCostUSD: 200.0, burnRatePerHour: 1.5)
        let payload = ForecastCachePayload(forecasts: [forecast])
        XCTAssertEqual(payload.schemaVersion, CacheSchema.currentVersion)
        let data = try makeEncoder().encode(payload)
        let decoded = try makeDecoder().decode(ForecastCachePayload.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, payload.schemaVersion)
        XCTAssertEqual(decoded.forecasts.count, 1)
        XCTAssertEqual(decoded.forecasts.first, forecast)
    }

    // MARK: - inferLegacyCostConfidence
    func testInferLegacyCostConfidenceClaudeCodeLocal() throws {
        let id = UUID()
        let json = """
        {
          "accountId": "\(id.uuidString)",
          "timestamp": "2026-01-01T00:00:00Z",
          "inputTokens": 10, "outputTokens": 5,
          "cacheCreationTokens": 0, "cacheReadTokens": 0,
          "totalCostUSD": 0.0,
          "modelBreakdown": [{"modelId":"claude-code-local","inputTokens":10,"outputTokens":5,"costUSD":0}]
        }
        """
        let snap = try makeDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.costConfidence, .estimated)
    }

    func testInferLegacyCostConfidenceSonnet() throws {
        let id = UUID()
        let json = """
        {
          "accountId": "\(id.uuidString)",
          "timestamp": "2026-01-01T00:00:00Z",
          "inputTokens": 10, "outputTokens": 5,
          "cacheCreationTokens": 0, "cacheReadTokens": 0,
          "totalCostUSD": 0.5,
          "modelBreakdown": [{"modelId":"claude-sonnet-4-6","inputTokens":10,"outputTokens":5,"costUSD":0.5}]
        }
        """
        let snap = try makeDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.costConfidence, .billingGrade)
    }
}
