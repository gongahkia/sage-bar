import Foundation
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "CacheManager")

private actor CacheStore {
    private static let retentionDays = 30
    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainISO8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private let cacheFile: URL
    private let forecastFile: URL
    private let anthropicCursorFile: URL
    private let anthropicRetryAfterFile: URL
    private let lastSuccessFile: URL

    init(baseURL: URL) {
        self.cacheFile = baseURL.appendingPathComponent("usage_cache.json")
        self.forecastFile = baseURL.appendingPathComponent("forecast_cache.json")
        self.anthropicCursorFile = baseURL.appendingPathComponent("anthropic_cursors.json")
        self.anthropicRetryAfterFile = baseURL.appendingPathComponent("anthropic_retry_after.json")
        self.lastSuccessFile = baseURL.appendingPathComponent("last_success_by_account.json")
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.fractionalISO8601Formatter.string(from: date))
        }
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let parsed = Self.fractionalISO8601Formatter.date(from: raw)
                ?? Self.plainISO8601Formatter.date(from: raw) {
                return parsed
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
        }
        return d
    }

    func loadSnapshots() -> [UsageSnapshot] {
        guard let data = try? Data(contentsOf: cacheFile) else { return [] }
        if let decoded = try? decoder().decode(UsageCachePayload.self, from: data) {
            let deduped = deduplicateSnapshots(decoded.snapshots)
            if deduped.count != decoded.snapshots.count {
                log.info("Deduplicated usage cache: \(decoded.snapshots.count) -> \(deduped.count)")
                saveSnapshots(deduped)
            }
            log.debug("Cache loaded: \(deduped.count) snapshots (schema \(decoded.schemaVersion))")
            return deduped
        }
        if let legacy = try? decoder().decode([UsageSnapshot].self, from: data) {
            log.info("Migrating legacy usage cache payload")
            let deduped = deduplicateSnapshots(legacy)
            saveSnapshots(deduped)
            return deduped
        }
        ErrorLogger.shared.log("JSON decode failed for usage_cache.json")
        return []
    }

    func saveSnapshots(_ snapshots: [UsageSnapshot]) {
        do {
            let payload = UsageCachePayload(snapshots: snapshots)
            let data = try encoder().encode(payload)
            try data.write(to: cacheFile, options: .atomic)
            log.debug("Cache saved: \(snapshots.count) snapshots")
        } catch {
            ErrorLogger.shared.log("Cache write failed: \(error.localizedDescription)")
        }
    }

    func appendSnapshot(_ snapshot: UsageSnapshot) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date())!
        var snapshots = loadSnapshots().filter { $0.timestamp >= cutoff }
        snapshots.append(snapshot)
        saveSnapshots(snapshots)
    }

    func upsertAnthropicSnapshots(_ incoming: [UsageSnapshot], forAccount id: UUID) {
        guard !incoming.isEmpty else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date())!
        var snapshots = loadSnapshots().filter { $0.timestamp >= cutoff }
        var indexByKey: [String: Int] = [:]
        for (i, snap) in snapshots.enumerated() {
            indexByKey[anthropicKey(for: snap)] = i
        }
        for snap in incoming where snap.accountId == id {
            let key = anthropicKey(for: snap)
            if let idx = indexByKey[key] {
                snapshots[idx] = snap
            } else {
                snapshots.append(snap)
                indexByKey[key] = snapshots.count - 1
            }
        }
        saveSnapshots(snapshots)
    }

    func latestSnapshot(forAccount id: UUID) -> UsageSnapshot? {
        loadSnapshots().filter { $0.accountId == id }.max(by: { $0.timestamp < $1.timestamp })
    }

    func historySnapshots(forAccount id: UUID, days: Int) -> [UsageSnapshot] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return loadSnapshots()
            .filter { $0.accountId == id && $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func todayAggregate(forAccount id: UUID) -> DailyAggregate {
        let cal = Calendar.current
        let today = cal.dateComponents([.year,.month,.day], from: Date())
        let raw = loadSnapshots().filter {
            $0.accountId == id &&
            cal.dateComponents([.year,.month,.day], from: $0.timestamp) == today
        }
        return DailyAggregate(date: today, snapshots: normalizeDailySnapshots(raw))
    }

    func latestForecast(forAccount id: UUID) -> ForecastSnapshot? {
        let forecasts = loadForecasts()
        return forecasts.filter { $0.accountId == id }.max(by: { $0.generatedAt < $1.generatedAt })
    }

    func saveForecast(_ forecast: ForecastSnapshot) {
        var forecasts = loadForecasts()
        forecasts.removeAll { $0.accountId == forecast.accountId }
        forecasts.append(forecast)
        saveForecasts(forecasts)
    }

    func loadCursor(forAccount id: UUID) -> AnthropicIngestionCursor? {
        guard let data = try? Data(contentsOf: anthropicCursorFile),
              let all = try? decoder().decode([String: AnthropicIngestionCursor].self, from: data) else { return nil }
        return all[id.uuidString]
    }

    func saveCursor(_ cursor: AnthropicIngestionCursor, forAccount id: UUID) {
        var all: [String: AnthropicIngestionCursor] = [:]
        if let data = try? Data(contentsOf: anthropicCursorFile),
           let decoded = try? decoder().decode([String: AnthropicIngestionCursor].self, from: data) {
            all = decoded
        }
        all[id.uuidString] = cursor
        do {
            let data = try encoder().encode(all)
            try data.write(to: anthropicCursorFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Anthropic cursor write failed: \(error.localizedDescription)")
        }
    }

    func loadRetryAfter(forAccount id: UUID) -> Date? {
        guard let data = try? Data(contentsOf: anthropicRetryAfterFile),
              let all = try? decoder().decode([String: Date].self, from: data) else { return nil }
        return all[id.uuidString]
    }

    func saveRetryAfter(_ retryAfter: Date, forAccount id: UUID) {
        var all: [String: Date] = [:]
        if let data = try? Data(contentsOf: anthropicRetryAfterFile),
           let decoded = try? decoder().decode([String: Date].self, from: data) {
            all = decoded
        }
        all[id.uuidString] = retryAfter
        do {
            let data = try encoder().encode(all)
            try data.write(to: anthropicRetryAfterFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Anthropic retryAfter write failed: \(error.localizedDescription)")
        }
    }

    func clearRetryAfter(forAccount id: UUID) {
        var all: [String: Date] = [:]
        if let data = try? Data(contentsOf: anthropicRetryAfterFile),
           let decoded = try? decoder().decode([String: Date].self, from: data) {
            all = decoded
        }
        all.removeValue(forKey: id.uuidString)
        do {
            let data = try encoder().encode(all)
            try data.write(to: anthropicRetryAfterFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Anthropic retryAfter clear failed: \(error.localizedDescription)")
        }
    }

    func loadLastSuccess(forAccount id: UUID) -> Date? {
        guard let data = try? Data(contentsOf: lastSuccessFile),
              let all = try? decoder().decode([String: Date].self, from: data) else { return nil }
        return all[id.uuidString]
    }

    func saveLastSuccess(_ date: Date, forAccount id: UUID) {
        var all: [String: Date] = [:]
        if let data = try? Data(contentsOf: lastSuccessFile),
           let decoded = try? decoder().decode([String: Date].self, from: data) {
            all = decoded
        }
        all[id.uuidString] = date
        do {
            let data = try encoder().encode(all)
            try data.write(to: lastSuccessFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Last-success write failed: \(error.localizedDescription)")
        }
    }

    private func anthropicKey(for snapshot: UsageSnapshot) -> String {
        let model = snapshot.modelBreakdown.first?.modelId ?? ""
        return "\(snapshot.accountId.uuidString)|\(snapshot.timestamp.ISO8601Format())|\(model)"
    }

    private func loadForecasts() -> [ForecastSnapshot] {
        guard let data = try? Data(contentsOf: forecastFile) else { return [] }
        if let decoded = try? decoder().decode(ForecastCachePayload.self, from: data) {
            return decoded.forecasts
        }
        if let legacy = try? decoder().decode([ForecastSnapshot].self, from: data) {
            log.info("Migrating legacy forecast cache payload")
            saveForecasts(legacy)
            return legacy
        }
        ErrorLogger.shared.log("Forecast decode failed")
        return []
    }

    private func saveForecasts(_ forecasts: [ForecastSnapshot]) {
        do {
            let payload = ForecastCachePayload(forecasts: forecasts)
            let data = try encoder().encode(payload)
            try data.write(to: forecastFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Forecast write failed: \(error.localizedDescription)")
        }
    }

    private func normalizeDailySnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        let cumulativeModels: Set<String> = [
            "claude-code-local",
            "claude-ai-web",
            "codex-local",
            "gemini-local",
            "openai-org",
            "windsurf-enterprise",
            "copilot-metrics",
        ]
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

    private func deduplicateSnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        var byKey: [String: UsageSnapshot] = [:]
        for snapshot in snapshots {
            let key = eventKey(for: snapshot)
            guard let existing = byKey[key] else {
                byKey[key] = snapshot
                continue
            }
            byKey[key] = preferredSnapshot(existing, snapshot)
        }
        return byKey.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func eventKey(for snapshot: UsageSnapshot) -> String {
        let modelId = snapshot.modelBreakdown.map(\.modelId).sorted().first ?? "unknown"
        let sourceType = sourceType(forModel: modelId)
        return "\(snapshot.accountId.uuidString)|\(snapshot.timestamp.ISO8601Format())|\(sourceType)|\(modelId)"
    }

    private func sourceType(forModel modelId: String) -> String {
        switch modelId {
        case "claude-code-local":
            return "claude-code"
        case "claude-ai-web":
            return "claude-ai-web"
        case "codex-local":
            return "codex-local"
        case "gemini-local":
            return "gemini-local"
        case "openai-org":
            return "openai-org"
        case "windsurf-enterprise":
            return "windsurf-enterprise"
        case "copilot-metrics":
            return "copilot-metrics"
        default:
            if modelId.hasPrefix("gemini-") {
                return "gemini-local"
            }
            if modelId.hasPrefix("claude-") {
                return "anthropic"
            }
            if modelId.hasPrefix("copilot-") {
                return "copilot-metrics"
            }
            return "unknown"
        }
    }

    private func preferredSnapshot(_ lhs: UsageSnapshot, _ rhs: UsageSnapshot) -> UsageSnapshot {
        let lhsTokenTotal = lhs.inputTokens + lhs.outputTokens + lhs.cacheCreationTokens + lhs.cacheReadTokens
        let rhsTokenTotal = rhs.inputTokens + rhs.outputTokens + rhs.cacheCreationTokens + rhs.cacheReadTokens
        let lhsScore = snapshotScore(lhs, tokenTotal: lhsTokenTotal)
        let rhsScore = snapshotScore(rhs, tokenTotal: rhsTokenTotal)
        if rhsScore > lhsScore { return rhs }
        return lhs
    }

    private func snapshotScore(_ snapshot: UsageSnapshot, tokenTotal: Int) -> (Int, Int, Int, Double, TimeInterval) {
        let confidence = snapshot.costConfidence == .billingGrade ? 1 : 0
        let freshness = snapshot.isStale ? 0 : 1
        return (confidence, freshness, tokenTotal, snapshot.totalCostUSD, snapshot.timestamp.timeIntervalSince1970)
    }
}

class CacheManager {
    static let shared = CacheManager()
    private let store: CacheStore

    init(baseURL: URL = AppConstants.sharedContainerURL) {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        self.store = CacheStore(baseURL: baseURL)
    }

    private func blocking<T>(_ operation: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var output: T! = nil
        Task.detached {
            output = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return output
    }

    func load() -> [UsageSnapshot] {
        blocking { await self.store.loadSnapshots() }
    }

    func save(_ snapshots: [UsageSnapshot]) {
        blocking {
            await self.store.saveSnapshots(snapshots)
        }
    }

    func append(_ snapshot: UsageSnapshot) {
        blocking {
            await self.store.appendSnapshot(snapshot)
        }
    }

    func upsertAnthropicSnapshots(_ incoming: [UsageSnapshot], forAccount id: UUID) {
        blocking {
            await self.store.upsertAnthropicSnapshots(incoming, forAccount: id)
        }
    }

    func latest(forAccount id: UUID) -> UsageSnapshot? {
        blocking { await self.store.latestSnapshot(forAccount: id) }
    }

    func history(forAccount id: UUID, days: Int) -> [UsageSnapshot] {
        blocking { await self.store.historySnapshots(forAccount: id, days: days) }
    }

    func todayAggregate(forAccount id: UUID) -> DailyAggregate {
        blocking { await self.store.todayAggregate(forAccount: id) }
    }

    func latestForecast(forAccount id: UUID) -> ForecastSnapshot? {
        blocking { await self.store.latestForecast(forAccount: id) }
    }

    func saveForecast(_ forecast: ForecastSnapshot) {
        blocking {
            await self.store.saveForecast(forecast)
        }
    }

    func loadAnthropicCursor(forAccount id: UUID) -> AnthropicIngestionCursor? {
        blocking { await self.store.loadCursor(forAccount: id) }
    }

    func saveAnthropicCursor(_ cursor: AnthropicIngestionCursor, forAccount id: UUID) {
        blocking {
            await self.store.saveCursor(cursor, forAccount: id)
        }
    }

    func loadAnthropicRetryAfter(forAccount id: UUID) -> Date? {
        blocking { await self.store.loadRetryAfter(forAccount: id) }
    }

    func saveAnthropicRetryAfter(_ retryAfter: Date, forAccount id: UUID) {
        blocking {
            await self.store.saveRetryAfter(retryAfter, forAccount: id)
        }
    }

    func clearAnthropicRetryAfter(forAccount id: UUID) {
        blocking {
            await self.store.clearRetryAfter(forAccount: id)
        }
    }

    func loadLastSuccess(forAccount id: UUID) -> Date? {
        blocking { await self.store.loadLastSuccess(forAccount: id) }
    }

    func saveLastSuccess(_ date: Date, forAccount id: UUID) {
        blocking {
            await self.store.saveLastSuccess(date, forAccount: id)
        }
    }
}
