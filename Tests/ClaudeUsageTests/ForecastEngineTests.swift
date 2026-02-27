import XCTest
@testable import ClaudeUsage

final class ForecastEngineTests: XCTestCase {
    private let accountId = UUID()

    private func snap(_ cost: Double, at date: Date) -> UsageSnapshot {
        UsageSnapshot(accountId: accountId, timestamp: date, inputTokens: 0, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: cost, modelBreakdown: [])
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
}
