import Foundation
import Combine

@MainActor
class PollingService: ObservableObject {
    static let shared = PollingService()
    @Published var lastPollDate: Date?
    @Published var isPolling: Bool = false

    private var timer: Timer?
    private var currentTask: Task<Void, Never>?
    private let maxConcurrency = 3

    private init() {}

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
        let config = ConfigManager.shared.load()
        isPolling = true
        defer { isPolling = false; lastPollDate = Date() }

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

    private func fetchAndStore(account: Account, config: Config) async {
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
                modelBreakdown: snap.modelBreakdown
            )
            CacheManager.shared.append(snap)
        case .anthropicAPI:
            guard let key = try? KeychainManager.retrieve(
                service: AppConstants.keychainService, account: account.id.uuidString
            ) else { return }
            let client = AnthropicAPIClient(apiKey: key)
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -1, to: end)!
            guard let response = try? await client.fetchUsage(startDate: start, endDate: end) else { return }
            for snap in client.convertToSnapshots(response, accountId: account.id) {
                CacheManager.shared.append(snap)
            }
        case .claudeAI:
            break // unsupported
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
                modelBreakdown: []
            )
            Task { try? await ws.send(event: .dailyDigest, snapshot: snap, config: config.webhook) }
        }
    }
}

extension Notification.Name {
    static let usageDidUpdate = Notification.Name("UsageDidUpdate")
}
