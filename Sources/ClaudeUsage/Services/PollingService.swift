import Foundation
import Combine
import Network
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "PollingService")

@MainActor
class PollingService: ObservableObject {
    static let shared = PollingService()
    @Published var lastPollDate: Date?
    @Published var isPolling: Bool = false
    @Published var lastFetchError: String?

    private var timer: Timer?
    private var currentTask: Task<Void, Never>?
    private let maxConcurrency = 3
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            self?.networkAvailable = available
            if !available {
                ErrorLogger.shared.log("Network unavailable, skipping polls until reconnect", level: "WARN")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.claudeusage.netmon"))
    }

    func start(config: Config) {
        stop()
        let interval = TimeInterval(config.pollIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.pollOnce() }
        }
        Task { await pollOnce() } // fire immediately
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentTask?.cancel()
        currentTask = nil
    }

    func forceRefresh() {
        currentTask?.cancel()
        Task { await pollOnce() }
    }

    func pollOnce() async {
        guard networkAvailable else {
            log.warning("Network unavailable, skipping poll")
            ErrorLogger.shared.log("Network unavailable, skipping poll", level: "WARN")
            return
        }
        let config = ConfigManager.shared.load()
        log.info("Poll started: \(config.accounts.filter { $0.isActive }.count) active accounts")
        isPolling = true
        defer { isPolling = false; lastPollDate = Date(); log.info("Poll completed") }

        let activeAccounts = config.accounts.filter { $0.isActive }
        var updatedIds: [UUID] = []

        await withTaskGroup(of: UUID?.self) { group in
            var launched = 0
            for account in activeAccounts {
                if launched >= maxConcurrency { _ = await group.next() }
                group.addTask { [account] in
                    await self.fetchAndStore(account: account, config: config)
                    return account.id
                }
                launched += 1
            }
            for await id in group {
                if let id { updatedIds.append(id) }
            }
        }

        // compute forecasts
        for account in activeAccounts {
            let history = CacheManager.shared.history(forAccount: account.id, days: 1)
            if let forecast = ForecastEngine.compute(history: history) {
                CacheManager.shared.saveForecast(forecast)
            }
        }

        // iCloud sync if enabled
        if config.iCloudSync.enabled {
            await iCloudSyncManager.shared.syncNow()
        }

        // daily digest check
        checkDailyDigest(config: config, accounts: activeAccounts)

        NotificationCenter.default.post(
            name: .usageDidUpdate,
            object: nil,
            userInfo: ["accountIds": updatedIds]
        )
    }

    internal func fetchAndStore(account: Account, config: Config) async {
        switch account.type {
        case .claudeCode:
            var snap = ClaudeCodeLogParser.shared.aggregateToday()
            snap = UsageSnapshot(
                accountId: account.id,
                timestamp: snap.timestamp,
                inputTokens: snap.inputTokens,
                outputTokens: snap.outputTokens,
                cacheCreationTokens: snap.cacheCreationTokens,
                cacheReadTokens: snap.cacheReadTokens,
                totalCostUSD: snap.totalCostUSD,
                modelBreakdown: snap.modelBreakdown,
                costConfidence: .estimated
            )
            CacheManager.shared.append(snap)
        case .anthropicAPI:
            let key: String
            do {
                key = try KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString)
            } catch {
                ErrorLogger.shared.log("Keychain failure for account \(account.id): \(error.localizedDescription)")
                return
            }
            do {
                // Anthropic Usage API remains the canonical billing source for anthropicAPI accounts.
                let result = try await fetchAnthropicCanonicalSnapshots(accountId: account.id, apiKey: key)
                let snapshots = result.snapshots
                CacheManager.shared.upsertAnthropicSnapshots(snapshots, forAccount: account.id)
                if let cursor = result.cursor {
                    CacheManager.shared.saveAnthropicCursor(cursor, forAccount: account.id)
                }
            } catch APIError.invalidKey {
                let msg = "Invalid API key for account \(account.id.uuidString)"
                ErrorLogger.shared.log(msg, file: #file, line: #line)
                lastFetchError = msg
            } catch APIError.rateLimited(let retryAfter) {
                let msg = "Rate limited for account \(account.id.uuidString); retry after \(retryAfter ?? 0)s"
                ErrorLogger.shared.log(msg, file: #file, line: #line)
                lastFetchError = msg
            } catch APIError.networkError(let underlying) {
                let msg = "Network error for account \(account.id.uuidString): \(underlying.localizedDescription)"
                ErrorLogger.shared.log(msg, file: #file, line: #line)
                lastFetchError = msg
            } catch {
                let msg = "Unexpected error for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(msg, file: #file, line: #line)
                lastFetchError = msg
            }
            lastFetchError = nil // clear on successful fetch
        case .claudeAI:
            let token: String
            do {
                token = try KeychainManager.retrieve(service: AppConstants.keychainSessionTokenService, account: account.id.uuidString)
            } catch {
                ErrorLogger.shared.log("No session token for claudeAI account \(account.id): \(error.localizedDescription)")
                return
            }
            let aiClient = ClaudeAIClient(sessionToken: token)
            if let usage = await aiClient.fetchUsage() {
                let snap = UsageSnapshot(
                    accountId: account.id,
                    timestamp: Date(),
                    inputTokens: usage.messagesUsed,
                    outputTokens: 0,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0,
                    totalCostUSD: 0,
                    modelBreakdown: [ModelUsage(modelId: "claude-ai-web", inputTokens: usage.messagesRemaining, outputTokens: 0, costUSD: 0)],
                    costConfidence: .estimated
                )
                CacheManager.shared.append(snap)
            } else {
                ErrorLogger.shared.log("claudeAI fetchUsage returned nil for account \(account.id.uuidString) — using cached snapshot", level: "WARN")
                if var cached = CacheManager.shared.latest(forAccount: account.id) {
                    cached.isStale = true
                    cached.timestamp = Date()
                    cached.costConfidence = .estimated
                    CacheManager.shared.append(cached)
                }
                NotificationCenter.default.post(name: .claudeAISessionExpired, object: account.id)
            }
        }
    }

    private func checkDailyDigest(config: Config, accounts: [Account]) {
        guard config.webhook.enabled, config.webhook.events.contains("daily_digest") else { return }
        let key = "lastDailyDigestDate"
        let cal = Calendar.current
        if let prev = UserDefaults.standard.object(forKey: key) as? Date,
           cal.isDateInToday(prev) { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let ws = WebhookService()
        for account in accounts {
            let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
            let snap = UsageSnapshot(
                accountId: account.id,
                timestamp: Date(),
                inputTokens: agg.totalInputTokens,
                outputTokens: agg.totalOutputTokens,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                totalCostUSD: agg.totalCostUSD,
                modelBreakdown: [],
                costConfidence: account.type == .anthropicAPI ? .billingGrade : .estimated
            )
            Task {
                do {
                    try await ws.send(event: .dailyDigest, snapshot: snap, config: config.webhook)
                } catch {
                    ErrorLogger.shared.log("Daily digest webhook failed for account \(account.id.uuidString): \(error.localizedDescription)", file: #file, line: #line)
                }
            }
        }
    }

    private func fetchAnthropicCanonicalSnapshots(accountId: UUID, apiKey: String) async throws -> (snapshots: [UsageSnapshot], cursor: AnthropicIngestionCursor?) {
        let client = AnthropicAPIClient(apiKey: apiKey)
        let end = Date()
        let cursor = CacheManager.shared.loadAnthropicCursor(forAccount: accountId)
        let start = Self.anthropicStartDate(cursor: cursor, now: end)
        let response = try await client.fetchUsage(startDate: start, endDate: end)
        return (client.convertToSnapshots(response, accountId: accountId), client.cursor(from: response))
    }

    static func anthropicStartDate(cursor: AnthropicIngestionCursor?, now: Date = Date()) -> Date {
        let fallback = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        guard let raw = cursor?.lastStartTime else { return fallback }
        guard let ts = ISO8601DateFormatter().date(from: raw) else { return fallback }
        return Calendar.current.startOfDay(for: ts)
    }
}

extension Notification.Name {
    static let usageDidUpdate = Notification.Name("UsageDidUpdate")
    static let claudeAISessionExpired = Notification.Name("ClaudeAISessionExpired")
}
