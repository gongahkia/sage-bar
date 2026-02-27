import Foundation

struct AnalyticsEngine {
    static func monthToDate(snapshots: [UsageSnapshot], account: UUID) -> DailyAggregate {
        let cal = Calendar.current
        let now = Date()
        let monthComps = cal.dateComponents([.year,.month], from: now)
        let filtered = snapshots.filter {
            $0.accountId == account &&
            cal.dateComponents([.year,.month], from: $0.timestamp) == monthComps
        }
        return DailyAggregate(date: cal.dateComponents([.year,.month,.day], from: now), snapshots: filtered)
    }

    static func rollingAverage(snapshots: [UsageSnapshot], days: Int, account: UUID) -> Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let filtered = snapshots.filter { $0.accountId == account && $0.timestamp >= cutoff }
        guard !filtered.isEmpty else { return 0 }
        let dailyTotals = Dictionary(grouping: filtered) {
            Calendar.current.startOfDay(for: $0.timestamp)
        }.mapValues { $0.reduce(0) { $0 + $1.totalCostUSD } }
        return dailyTotals.values.reduce(0, +) / Double(dailyTotals.count)
    }

    /// 7×24 grid [weekday][hour] of average cost, normalised to [0,1]
    static func heatmap(snapshots: [UsageSnapshot], account: UUID) -> [[Double]] {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let cal = Calendar.current
        for snap in snapshots where snap.accountId == account {
            let weekday = (cal.component(.weekday, from: snap.timestamp) - 2 + 7) % 7 // Mon=0
            let hour = cal.component(.hour, from: snap.timestamp)
            grid[weekday][hour] += snap.totalCostUSD
            counts[weekday][hour] += 1
        }
        let maxVal = grid.flatMap { $0 }.max() ?? 1
        return grid.map { row in
            row.map { val in maxVal > 0 ? val / maxVal : 0 }
        }
    }
}
