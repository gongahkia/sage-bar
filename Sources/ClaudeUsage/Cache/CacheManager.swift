import Foundation

class CacheManager {
    static let shared = CacheManager()
    private let cacheFile: URL
    private let forecastFile: URL
    private let coordinator = NSFileCoordinator()
    private let queue = DispatchQueue(label: "dev.claudeusage.cache", qos: .utility)
    private static let retentionDays = 30

    private init() {
        let base = AppConstants.sharedContainerURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.cacheFile = base.appendingPathComponent("usage_cache.json")
        self.forecastFile = base.appendingPathComponent("forecast_cache.json")
    }

    // MARK: – UsageSnapshot

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601 // cross-binary compatibility
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func load() -> [UsageSnapshot] {
        var result: [UsageSnapshot] = []
        var err: NSError?
        coordinator.coordinate(readingItemAt: cacheFile, options: [], error: &err) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            result = (try? decoder().decode([UsageSnapshot].self, from: data)) ?? []
        }
        return result
    }

    func save(_ snapshots: [UsageSnapshot]) {
        var err: NSError?
        coordinator.coordinate(writingItemAt: cacheFile, options: .forReplacing, error: &err) { url in
            guard let data = try? encoder().encode(snapshots) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func append(_ snapshot: UsageSnapshot) {
        queue.async {
            let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date())!
            var snapshots = self.load().filter { $0.timestamp >= cutoff }
            snapshots.append(snapshot)
            self.save(snapshots)
        }
    }

    func latest(forAccount id: UUID) -> UsageSnapshot? {
        load().filter { $0.accountId == id }.max(by: { $0.timestamp < $1.timestamp })
    }

    func history(forAccount id: UUID, days: Int) -> [UsageSnapshot] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return load()
            .filter { $0.accountId == id && $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func todayAggregate(forAccount id: UUID) -> DailyAggregate {
        let cal = Calendar.current
        let today = cal.dateComponents([.year,.month,.day], from: Date())
        let snaps = load().filter {
            $0.accountId == id &&
            cal.dateComponents([.year,.month,.day], from: $0.timestamp) == today
        }
        return DailyAggregate(date: today, snapshots: snaps)
    }

    // MARK: – ForecastSnapshot

    func latestForecast(forAccount id: UUID) -> ForecastSnapshot? {
        guard let data = try? Data(contentsOf: forecastFile),
              let forecasts = try? decoder().decode([ForecastSnapshot].self, from: data) else { return nil }
        return forecasts.filter { $0.accountId == id }.max(by: { $0.generatedAt < $1.generatedAt })
    }

    func saveForecast(_ forecast: ForecastSnapshot) {
        var forecasts: [ForecastSnapshot] = []
        if let data = try? Data(contentsOf: forecastFile) {
            forecasts = (try? decoder().decode([ForecastSnapshot].self, from: data)) ?? []
        }
        forecasts.removeAll { $0.accountId == forecast.accountId }
        forecasts.append(forecast)
        if let data = try? encoder().encode(forecasts) {
            try? data.write(to: forecastFile, options: .atomic)
        }
    }
}
