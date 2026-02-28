import Foundation
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "CacheManager")

class CacheManager {
    static let shared = CacheManager()
    private let cacheFile: URL
    private let forecastFile: URL
    private let anthropicCursorFile: URL
    private let coordinator = NSFileCoordinator()
    private let queue = DispatchQueue(label: "dev.claudeusage.cache", qos: .utility)
    private static let retentionDays = 30

    init(baseURL: URL = AppConstants.sharedContainerURL) {
        let base = baseURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.cacheFile = base.appendingPathComponent("usage_cache.json")
        self.forecastFile = base.appendingPathComponent("forecast_cache.json")
        self.anthropicCursorFile = base.appendingPathComponent("anthropic_cursors.json")
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

    func upsertAnthropicSnapshots(_ incoming: [UsageSnapshot], forAccount id: UUID) {
        queue.async {
            guard !incoming.isEmpty else { return }
            let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date())!
            var snapshots = self.load().filter { $0.timestamp >= cutoff }
            var indexByKey: [String: Int] = [:]
            for (i, snap) in snapshots.enumerated() {
                indexByKey[self.anthropicKey(for: snap)] = i
            }
            for snap in incoming {
                guard snap.accountId == id else { continue }
                let key = self.anthropicKey(for: snap)
                if let idx = indexByKey[key] {
                    snapshots[idx] = snap
                } else {
                    snapshots.append(snap)
                    indexByKey[key] = snapshots.count - 1
                }
            }
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
        let raw = load().filter {
            $0.accountId == id &&
            cal.dateComponents([.year,.month,.day], from: $0.timestamp) == today
        }
        return DailyAggregate(date: today, snapshots: normalizeDailySnapshots(raw))
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

    // MARK: - Anthropic cursor

    func loadAnthropicCursor(forAccount id: UUID) -> AnthropicIngestionCursor? {
        guard let data = try? Data(contentsOf: anthropicCursorFile) else { return nil }
        let dec = JSONDecoder()
        guard let all = try? dec.decode([String: AnthropicIngestionCursor].self, from: data) else {
            ErrorLogger.shared.log("Anthropic cursor decode failed")
            return nil
        }
        return all[id.uuidString]
    }

    func saveAnthropicCursor(_ cursor: AnthropicIngestionCursor, forAccount id: UUID) {
        queue.async {
            var all: [String: AnthropicIngestionCursor] = [:]
            if let data = try? Data(contentsOf: self.anthropicCursorFile),
               let decoded = try? self.decoder().decode([String: AnthropicIngestionCursor].self, from: data) {
                all = decoded
            }
            all[id.uuidString] = cursor
            do {
                let data = try self.encoder().encode(all)
                try data.write(to: self.anthropicCursorFile, options: .atomic)
            } catch {
                ErrorLogger.shared.log("Anthropic cursor write failed: \(error.localizedDescription)")
            }
        }
    }

    private func anthropicKey(for snapshot: UsageSnapshot) -> String {
        let model = snapshot.modelBreakdown.first?.modelId ?? ""
        return "\(snapshot.accountId.uuidString)|\(snapshot.timestamp.ISO8601Format())|\(model)"
    }

    private func normalizeDailySnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        let cumulativeModels: Set<String> = ["claude-code-local", "claude-ai-web"]
        var eventSnapshots: [UsageSnapshot] = []
        var cumulativeSnapshots: [UsageSnapshot] = []
        for snap in snapshots {
            let model = snap.modelBreakdown.first?.modelId ?? ""
            if cumulativeModels.contains(model) {
                cumulativeSnapshots.append(snap)
            } else {
                eventSnapshots.append(snap)
            }
        }
        if let latestCumulative = cumulativeSnapshots.max(by: { $0.timestamp < $1.timestamp }) {
            eventSnapshots.append(latestCumulative)
        }
        return eventSnapshots
    }
}
