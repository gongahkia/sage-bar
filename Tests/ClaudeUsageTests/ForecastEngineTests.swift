import XCTest
@testable import ClaudeUsage

final class ForecastEngineTests: XCTestCase {
    private let accountId = UUID()

    private func snap(_ cost: Double, at date: Date) -> UsageSnapshot {
        UsageSnapshot(accountId: accountId, timestamp: date, inputTokens: 0, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: cost, modelBreakdown: [])
    }

    private func cumulativeSnap(_ cost: Double, at date: Date, modelId: String = "codex-local") -> UsageSnapshot {
        UsageSnapshot(
            accountId: accountId,
            timestamp: date,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: cost,
            modelBreakdown: [ModelUsage(modelId: modelId, inputTokens: 0, outputTokens: 0, costUSD: cost)]
        )
    }

    func testZeroSnapshotsReturnsNil() {
        XCTAssertNil(ForecastEngine.compute(history: []))
    }

    func testSingleSnapshotReturnsNil() {
        let now = Date()
        let result = ForecastEngine.compute(history: [snap(1.0, at: now)], now: now)
        XCTAssertNil(result)
    }

    func testZeroBurnRateReturnsNilWhenElapsedIsZero() {
        let t = Date()
        let result = ForecastEngine.compute(history: [snap(0, at: t), snap(0, at: t)], now: t)
        XCTAssertNil(result)
    }

    func testEODMathIsCorrect() {
        let cal = Calendar.current
        // pin "now" to noon today so hoursLeftInDay == 12
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 12; comps.minute = 0; comps.second = 0
        let noon = cal.date(from: comps)!
        let t0 = noon.addingTimeInterval(-3600) // 11:00 — 1h earlier, cost 0
        let t1 = noon                            // 12:00 — cost 2.0
        let snaps = [snap(0, at: t0), snap(2.0, at: t1)]
        let result = ForecastEngine.compute(history: snaps, now: noon)!
        // burnPerHour = 2.0/1.0 = 2.0; hoursLeft ≈ 12; eod ≈ 2 + 2*12 = 26
        XCTAssertEqual(result.burnRatePerHour, 2.0, accuracy: 0.001)
        XCTAssertEqual(result.projectedEODCostUSD, 2.0 + 2.0 * 12.0, accuracy: 0.01)
    }

    func testCumulativeCostUsesSumOfTodaySnapshots() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 12; comps.minute = 0; comps.second = 0
        let noon = cal.date(from: comps)!
        let snaps = [snap(1.0, at: noon.addingTimeInterval(-3600)), snap(2.0, at: noon)]
        let result = ForecastEngine.compute(history: snaps, now: noon)!
        XCTAssertEqual(result.burnRatePerHour, 3.0, accuracy: 0.001)
    }

    func testBurnRateUsesHourlyBucketSpanForCumulativeDeltas() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 2; comps.minute = 30; comps.second = 0
        let now = cal.date(from: comps)!
        let snaps = [
            snap(4.0, at: now.addingTimeInterval(-2 * 3600 + 120)), // bucket hour-2
            snap(2.0, at: now.addingTimeInterval(-300)),             // current bucket
        ]
        let result = ForecastEngine.compute(history: snaps, now: now)!
        XCTAssertEqual(result.burnRatePerHour, 3.0, accuracy: 0.001)
    }

    // MARK: - Task 57: all-zero snapshots → zero projections

    func testAllZeroSnapshotsReturnZeroCosts() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year,.month,.day], from: Date())
        comps.hour = 12; comps.minute = 0; comps.second = 0
        let noon = cal.date(from: comps)!
        let snaps = [snap(0, at: noon.addingTimeInterval(-3600)), snap(0, at: noon)]
        let result = ForecastEngine.compute(history: snaps, now: noon)!
        XCTAssertEqual(result.projectedEODCostUSD, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result.projectedEOWCostUSD, 0.0, accuracy: 0.0001)
        XCTAssertEqual(result.projectedEOMCostUSD, 0.0, accuracy: 0.0001)
    }

    // MARK: - Task 58: eodCost proportional to remaining hours

    func testEODCostProportionalToRemainingHours() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year,.month,.day], from: Date())
        comps.hour = 6; comps.minute = 0; comps.second = 0
        let sixAM = cal.date(from: comps)!
        // 1h elapsed, cost = 4.0 → burnPerHour = 4.0; 18h remain until midnight → eod = 4 + 4*18 = 76
        let snaps = [snap(0, at: sixAM.addingTimeInterval(-3600)), snap(4.0, at: sixAM)]
        let result = ForecastEngine.compute(history: snaps, now: sixAM)!
        let hoursLeft = 24.0 - 6.0 // 18h
        let expected = 4.0 + 4.0 * hoursLeft
        XCTAssertEqual(result.projectedEODCostUSD, expected, accuracy: 0.1)
    }

    // MARK: - Task 59: lower second-half spend decreases burn rate vs first-half only

    func testBurnRateDecreasesWithLowerSecondHalfSpend() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year,.month,.day], from: Date())
        comps.hour = 12; comps.minute = 0; comps.second = 0
        let noon = cal.date(from: comps)!
        // first half: 5h elapsed, summed cost=12 → burnRate=2.4
        let firstHalfOnly = [snap(4.0, at: noon.addingTimeInterval(-6*3600)), snap(8.0, at: noon.addingTimeInterval(-3600))]
        let r1 = ForecastEngine.compute(history: firstHalfOnly, now: noon.addingTimeInterval(-3600))!
        // all day: 12h elapsed, summed cost=13 (slow second half) → burnRate=13/12 ≈ 1.08
        let allDay = [
            snap(4.0, at: noon.addingTimeInterval(-12*3600)),
            snap(8.0, at: noon.addingTimeInterval(-6*3600)),
            snap(1.0, at: noon),
        ]
        let r2 = ForecastEngine.compute(history: allDay, now: noon)!
        XCTAssertLessThan(r2.burnRatePerHour, r1.burnRatePerHour, "slower second-half spend should produce lower overall burn rate")
    }

    func testEOWAndEOMPositive() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 12; comps.minute = 0; comps.second = 0
        let noon = cal.date(from: comps)!
        let snaps = [snap(0, at: noon.addingTimeInterval(-3600)), snap(1.0, at: noon)]
        let result = ForecastEngine.compute(history: snaps, now: noon)!
        XCTAssertGreaterThanOrEqual(result.projectedEOWCostUSD, result.projectedEODCostUSD)
        XCTAssertGreaterThanOrEqual(result.projectedEOMCostUSD, result.projectedEODCostUSD)
    }

    func testCumulativeProviderBurnRateUsesCostDeltas() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 12; comps.minute = 0; comps.second = 0
        let noon = cal.date(from: comps)!
        let snaps = [
            cumulativeSnap(1.0, at: noon.addingTimeInterval(-2 * 3600)),
            cumulativeSnap(3.0, at: noon.addingTimeInterval(-1 * 3600)),
            cumulativeSnap(4.0, at: noon),
        ]
        let result = ForecastEngine.compute(history: snaps, now: noon)!
        XCTAssertEqual(result.burnRatePerHour, 2.0, accuracy: 0.001)
        XCTAssertEqual(result.projectedEODCostUSD, 4.0 + 2.0 * 12.0, accuracy: 0.1)
    }

    func testCumulativeProviderCounterResetTreatedAsFreshDelta() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 11; comps.minute = 0; comps.second = 0
        let eleven = cal.date(from: comps)!
        let snaps = [
            cumulativeSnap(5.0, at: eleven.addingTimeInterval(-2 * 3600)),
            cumulativeSnap(1.0, at: eleven.addingTimeInterval(-1 * 3600)), // reset
            cumulativeSnap(3.0, at: eleven),
        ]
        let result = ForecastEngine.compute(history: snaps, now: eleven)!
        XCTAssertGreaterThan(result.burnRatePerHour, 0)
        XCTAssertGreaterThan(result.projectedEODCostUSD, 3.0)
    }
}
