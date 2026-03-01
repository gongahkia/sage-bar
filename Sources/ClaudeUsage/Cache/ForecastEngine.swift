import Foundation

struct ForecastEngine {
    /// returns nil if fewer than 2 snapshots exist for today (insufficient data)
    static func compute(history: [UsageSnapshot], now: Date = Date()) -> ForecastSnapshot? {
        guard let accountId = history.first?.accountId else { return nil }
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.year,.month,.day], from: now)
        let todaySnaps = history.filter {
            cal.dateComponents([.year,.month,.day], from: $0.timestamp) == todayComps
        }.sorted { $0.timestamp < $1.timestamp }
        guard todaySnaps.count >= 2 else { return nil }

        let first = todaySnaps.first!
        let last = todaySnaps.last!
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp) / 3600.0
        guard elapsed > 0 else { return nil }
        let eventCost = todaySnaps
            .filter { !isCumulativeSnapshot($0) }
            .reduce(0) { $0 + max(0, $1.totalCostUSD) }
        let latestCumulativeCost = todaySnaps
            .filter { isCumulativeSnapshot($0) }
            .map(\.totalCostUSD)
            .max() ?? 0
        let cumulativeCost = max(0, eventCost + latestCumulativeCost)
        let deltas = dailyCostDeltas(from: todaySnaps)
        let burnPerHour = burnRateFromHourlyBuckets(
            deltas: deltas,
            calendar: cal,
            cumulativeCost: cumulativeCost,
            fallbackElapsedHours: elapsed
        )

        let startOfDay = cal.startOfDay(for: now)
        let hoursSinceMidnight = now.timeIntervalSince(startOfDay) / 3600.0
        let hoursLeftInDay = max(0, 24 - hoursSinceMidnight)
        let eod = max(0, cumulativeCost + burnPerHour * hoursLeftInDay)

        let weekday = cal.component(.weekday, from: now) // 1=Sun
        let fullDaysAfterTodayInWeek = weekday == 1 ? 0.0 : Double(8 - weekday) // Mon->6 ... Sat->1
        let hoursLeftInWeek = hoursLeftInDay + fullDaysAfterTodayInWeek * 24.0
        let eow = max(0, cumulativeCost + burnPerHour * hoursLeftInWeek)

        let range = cal.range(of: .day, in: .month, for: now)!
        let dayOfMonth = cal.component(.day, from: now)
        let fullDaysAfterTodayInMonth = Double(max(0, range.count - dayOfMonth))
        let hoursLeftInMonth = hoursLeftInDay + fullDaysAfterTodayInMonth * 24.0
        let eom = max(0, cumulativeCost + burnPerHour * hoursLeftInMonth)

        return ForecastSnapshot(
            accountId: accountId,
            generatedAt: now,
            projectedEODCostUSD: eod,
            projectedEOWCostUSD: eow,
            projectedEOMCostUSD: eom,
            burnRatePerHour: burnPerHour
        )
    }

    private static func burnRateFromHourlyBuckets(
        deltas: [(timestamp: Date, costDelta: Double)],
        calendar: Calendar,
        cumulativeCost: Double,
        fallbackElapsedHours: Double
    ) -> Double {
        var hourlyTotals: [Date: Double] = [:]
        for delta in deltas where delta.costDelta > 0 {
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: delta.timestamp)
            guard let hour = calendar.date(from: comps) else { continue }
            hourlyTotals[hour, default: 0] += delta.costDelta
        }
        guard let firstHour = hourlyTotals.keys.min(),
              let lastHour = hourlyTotals.keys.max() else {
            return cumulativeCost / fallbackElapsedHours
        }
        let spanHours = lastHour.timeIntervalSince(firstHour) / 3600.0
        guard spanHours > 0 else { return cumulativeCost / fallbackElapsedHours }
        let totalDelta = hourlyTotals.values.reduce(0, +)
        return totalDelta / spanHours
    }

    private static func dailyCostDeltas(from snapshots: [UsageSnapshot]) -> [(timestamp: Date, costDelta: Double)] {
        var deltas: [(Date, Double)] = []
        var previousCumulativeCost: Double?
        for snapshot in snapshots {
            if isCumulativeSnapshot(snapshot) {
                let currentCost = max(0, snapshot.totalCostUSD)
                let delta: Double
                if let previous = previousCumulativeCost {
                    delta = currentCost >= previous ? (currentCost - previous) : currentCost
                } else {
                    delta = currentCost
                }
                previousCumulativeCost = currentCost
                if delta > 0 {
                    deltas.append((snapshot.timestamp, delta))
                }
            } else {
                let delta = max(0, snapshot.totalCostUSD)
                if delta > 0 {
                    deltas.append((snapshot.timestamp, delta))
                }
            }
        }
        return deltas
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
