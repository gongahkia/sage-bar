import Foundation
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "CacheManager")

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
            do {
                let data = try Data(contentsOf: url)
                result = (try? decoder().decode([UsageSnapshot].self, from: data)) ?? {
                    ErrorLogger.shared.log("JSON decode failed for usage_cache.json")
                    return []
                }()
            } catch {
                ErrorLogger.shared.log("Cache read failed: \(error.localizedDescription)")
            }
        }
        if let e = err { ErrorLogger.shared.log("NSFileCoordinator cache read error: \(e.localizedDescription)") }
        log.debug("Cache loaded: \(result.count) snapshots")
        return result
    }

    func save(_ snapshots: [UsageSnapshot]) {
        var err: NSError?
        coordinator.coordinate(writingItemAt: cacheFile, options: .forReplacing, error: &err) { url in
            do {
                let data = try encoder().encode(snapshots)
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    ErrorLogger.shared.log("Cache write failed: \(error.localizedDescription)")
                }
            } catch {
                ErrorLogger.shared.log("Cache encode failed: \(error.localizedDescription)")
            }
        }
        if let e = err { ErrorLogger.shared.log("NSFileCoordinator cache write error: \(e.localizedDescription)") }
        log.debug("Cache saved: \(snapshots.count) snapshots")
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
        do {
            let data = try Data(contentsOf: forecastFile)
            do {
                let forecasts = try decoder().decode([ForecastSnapshot].self, from: data)
                return forecasts.filter { $0.accountId == id }.max(by: { $0.generatedAt < $1.generatedAt })
            } catch {
                ErrorLogger.shared.log("Forecast decode failed: \(error.localizedDescription)")
                return nil
            }
        } catch {
            ErrorLogger.shared.log("Forecast read failed: \(error.localizedDescription)")
            return nil
        }
    }

    func saveForecast(_ forecast: ForecastSnapshot) {
        var forecasts: [ForecastSnapshot] = []
        do {
            let data = try Data(contentsOf: forecastFile)
            forecasts = (try? decoder().decode([ForecastSnapshot].self, from: data)) ?? []
        } catch {
            ErrorLogger.shared.log("Forecast read for save failed: \(error.localizedDescription)")
        }
        forecasts.removeAll { $0.accountId == forecast.accountId }
        forecasts.append(forecast)
        do {
            let data = try encoder().encode(forecasts)
            do {
                try data.write(to: forecastFile, options: .atomic)
            } catch {
                ErrorLogger.shared.log("Forecast write failed: \(error.localizedDescription)")
            }
        } catch {
            ErrorLogger.shared.log("Forecast encode failed: \(error.localizedDescription)")
        }
    }
}
