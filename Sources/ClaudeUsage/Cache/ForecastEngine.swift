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
        let cumulativeCost = todaySnaps.reduce(0) { $0 + $1.totalCostUSD }
        let burnPerHour = burnRateFromHourlyBuckets(
            snapshots: todaySnaps,
            calendar: cal,
            cumulativeCost: cumulativeCost,
            fallbackElapsedHours: elapsed
        )

        let startOfDay = cal.startOfDay(for: now)
        let hoursSinceMidnight = now.timeIntervalSince(startOfDay) / 3600.0
        let hoursLeftInDay = max(0, 24 - hoursSinceMidnight)
        let eod = max(0, cumulativeCost + burnPerHour * hoursLeftInDay)

        let weekday = cal.component(.weekday, from: now) // 1=Sun
        let daysLeftInWeek = Double(8 - weekday) // days until end of Sun
        let eow = max(0, cumulativeCost + burnPerHour * daysLeftInWeek * 24)

        let range = cal.range(of: .day, in: .month, for: now)!
        let dayOfMonth = cal.component(.day, from: now)
        let daysLeftInMonth = Double(range.count - dayOfMonth)
        let eom = max(0, cumulativeCost + burnPerHour * daysLeftInMonth * 24)

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
        snapshots: [UsageSnapshot],
        calendar: Calendar,
        cumulativeCost: Double,
        fallbackElapsedHours: Double
    ) -> Double {
        var hourlyTotals: [Date: Double] = [:]
        for snap in snapshots {
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: snap.timestamp)
            guard let hour = calendar.date(from: comps) else { continue }
            hourlyTotals[hour, default: 0] += snap.totalCostUSD
        }
        guard let firstHour = hourlyTotals.keys.min(),
              let lastHour = hourlyTotals.keys.max() else {
            return cumulativeCost / fallbackElapsedHours
        }
        let spanHours = lastHour.timeIntervalSince(firstHour) / 3600.0
        guard spanHours > 0 else { return cumulativeCost / fallbackElapsedHours }
        return cumulativeCost / spanHours
    }
}
