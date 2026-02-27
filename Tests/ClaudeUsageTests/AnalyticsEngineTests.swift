import XCTest
@testable import ClaudeUsage

final class AnalyticsEngineTests: XCTestCase {
    private let accountId = UUID()
    private let otherAccountId = UUID()

    private func snap(_ cost: Double, at date: Date, account: UUID? = nil) -> UsageSnapshot {
        UsageSnapshot(accountId: account ?? accountId, timestamp: date, inputTokens: 100,
            outputTokens: 50, cacheCreationTokens: 0, cacheReadTokens: 0,
            totalCostUSD: cost, modelBreakdown: [])
    }

    // MARK: - monthToDate

    func testMTDAggregationOnlyCurrentMonth() {
        let cal = Calendar.current
        let now = Date()
        let lastMonth = cal.date(byAdding: .month, value: -1, to: now)!
        let snaps = [snap(5.0, at: now), snap(10.0, at: lastMonth)]
        let agg = AnalyticsEngine.monthToDate(snapshots: snaps, account: accountId)
        XCTAssertEqual(agg.totalCostUSD, 5.0, accuracy: 0.001)
    }

    func testMTDFiltersByAccount() {
        let now = Date()
        let snaps = [snap(3.0, at: now), snap(7.0, at: now, account: otherAccountId)]
        let agg = AnalyticsEngine.monthToDate(snapshots: snaps, account: accountId)
        XCTAssertEqual(agg.totalCostUSD, 3.0, accuracy: 0.001)
    }

    func testMTDEmptyInputReturnsZero() {
        let agg = AnalyticsEngine.monthToDate(snapshots: [], account: accountId)
        XCTAssertEqual(agg.totalCostUSD, 0.0)
    }

    // MARK: - rollingAverage

    func testRollingAverageCorrect() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        // day1: $2, day2: $4 → avg = $3
        let snaps = [snap(2.0, at: yesterday), snap(4.0, at: now)]
        let avg = AnalyticsEngine.rollingAverage(snapshots: snaps, days: 7, account: accountId)
        XCTAssertEqual(avg, 3.0, accuracy: 0.001)
    }

    func testRollingAverageEmptyReturnsZero() {
        XCTAssertEqual(AnalyticsEngine.rollingAverage(snapshots: [], days: 7, account: accountId), 0)
    }

    // MARK: - heatmap

    func testHeatmap7x24Shape() {
        let grid = AnalyticsEngine.heatmap(snapshots: [], account: accountId)
        XCTAssertEqual(grid.count, 7)
        XCTAssertTrue(grid.allSatisfy { $0.count == 24 })
    }

    func testHeatmapNormalisedTo0to1() {
        let now = Date()
        let snaps = [snap(10.0, at: now), snap(5.0, at: now.addingTimeInterval(-3600))]
        let grid = AnalyticsEngine.heatmap(snapshots: snaps, account: accountId)
        let allValues = grid.flatMap { $0 }
        XCTAssertTrue(allValues.allSatisfy { $0 >= 0 && $0 <= 1.0 })
        XCTAssertEqual(allValues.max()!, 1.0, accuracy: 0.001)
    }

    func testHeatmapEmptyInputAllZeros() {
        let grid = AnalyticsEngine.heatmap(snapshots: [], account: accountId)
        XCTAssertTrue(grid.flatMap { $0 }.allSatisfy { $0 == 0.0 })
    }
}
