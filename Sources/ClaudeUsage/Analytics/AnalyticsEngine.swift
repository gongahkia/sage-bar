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
        let normalized = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.timestamp) }
            .values
            .flatMap { normalizeDailySnapshots($0) }
            .sorted { $0.timestamp < $1.timestamp }
        return DailyAggregate(date: cal.dateComponents([.year,.month,.day], from: now), snapshots: normalized)
    }

    static func rollingAverage(snapshots: [UsageSnapshot], days: Int, account: UUID) -> Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let filtered = snapshots.filter { $0.accountId == account && $0.timestamp >= cutoff }
        guard !filtered.isEmpty else { return 0 }
        let dailyTotals = Dictionary(grouping: filtered) {
            Calendar.current.startOfDay(for: $0.timestamp)
        }.mapValues { daySnapshots in
            normalizeDailySnapshots(daySnapshots).reduce(0) { $0 + $1.totalCostUSD }
        }
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

    private static func normalizeDailySnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        var eventSnapshots: [UsageSnapshot] = []
        var cumulativeSnapshots: [UsageSnapshot] = []
        for snapshot in snapshots {
            if isCumulativeSnapshot(snapshot) {
                cumulativeSnapshots.append(snapshot)
            } else {
                eventSnapshots.append(snapshot)
            }
        }
        if let latestCumulative = cumulativeSnapshots.max(by: { $0.timestamp < $1.timestamp }) {
            eventSnapshots.append(latestCumulative)
        }
        return eventSnapshots
    }

    private static func isCumulativeSnapshot(_ snapshot: UsageSnapshot) -> Bool {
        let model = snapshot.modelBreakdown.first?.modelId ?? ""
        let cumulativeModels: Set<String> = [
            "claude-code-local",
            "claude-ai-web",
            "codex-local",
            "gemini-local",
            "openai-org",
            "windsurf-enterprise",
            "copilot-metrics",
        ]
        return cumulativeModels.contains(model)
    }
}
