import Foundation
import Combine
import Network
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "PollingService")

class PollingService: ObservableObject {
    static let shared = PollingService()
    @MainActor @Published var lastPollDate: Date?
    @MainActor @Published var isPolling: Bool = false
    @MainActor @Published var lastFetchError: String?

    private var timer: Timer?
    private var currentTask: Task<Void, Never>?
    @MainActor private var currentPollToken: UUID?
    private let maxConcurrency = 3
    private let pathMonitor = NWPathMonitor()
    @MainActor private var networkAvailable = true
    @MainActor private var pendingLogRefresh = false
    @MainActor private var logChangeDebounceTask: Task<Void, Never>?

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkAvailable = available }
            if !available {
                ErrorLogger.shared.log("Network unavailable, skipping polls until reconnect", level: "WARN")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.claudeusage.netmon"))
    }

    @MainActor
    func start(config: Config) {
        stop()
        let interval = TimeInterval(config.pollIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { await PollingService.shared.pollOnce() }
        }
        Task { await pollOnce() } // fire immediately
    }

    @MainActor
    func stop() {
        timer?.invalidate()
        timer = nil
        currentTask?.cancel()
        currentTask = nil
        currentPollToken = nil
        pendingLogRefresh = false
        logChangeDebounceTask?.cancel()
        logChangeDebounceTask = nil
    }

    @MainActor
    func forceRefresh() {
        currentTask?.cancel()
        Task { await pollOnce() }
    }

    func handleClaudeCodeLogsChanged() async {
        let pollInProgress = await MainActor.run { self.currentTask != nil || self.isPolling }
        if pollInProgress {
            await MainActor.run { self.pendingLogRefresh = true }
            return
        }
        await scheduleDebouncedLogRefresh()
    }

    func pollOnce() async {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPollCycle()
        }
        await MainActor.run {
            self.currentTask = task
            self.currentPollToken = token
        }
        await task.value
        await MainActor.run {
            if self.currentPollToken == token {
                self.currentTask = nil
                self.currentPollToken = nil
            }
        }
    }

    private func runPollCycle() async {
        guard !Task.isCancelled else { return }
        let available = await MainActor.run { self.networkAvailable }
        guard available else {
            log.warning("Network unavailable, skipping poll")
            ErrorLogger.shared.log("Network unavailable, skipping poll", level: "WARN")
            return
        }
        var config = ConfigManager.shared.load()
        log.info("Poll started: \(config.accounts.filter { $0.isActive }.count) active accounts")
        await MainActor.run { self.isPolling = true }
        defer {
            Task { @MainActor in
                self.isPolling = false
                self.lastPollDate = Date()
                log.info("Poll completed")
            }
        }

        let activeAccounts = config.accounts.filter { $0.isActive }
        var updatedIds: [UUID] = []

        await withTaskGroup(of: UUID?.self) { group in
            var launched = 0
            for account in activeAccounts {
                if launched >= maxConcurrency { _ = await group.next() }
                group.addTask { [account] in
                    guard !Task.isCancelled else { return nil }
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
            guard !Task.isCancelled else { return }
            let history = CacheManager.shared.history(forAccount: account.id, days: 1)
            if let forecast = ForecastEngine.compute(history: history) {
                CacheManager.shared.saveForecast(forecast)
            }
        }

        // iCloud sync if enabled
        if config.iCloudSync.enabled {
            await iCloudSyncManager.shared.syncNow()
        }

        // threshold notifications
        guard !Task.isCancelled else { return }
        checkThresholds(config: config, accounts: activeAccounts)

        // automation evaluation
        let matchedAutomations = evaluateAutomations(config: config, accounts: activeAccounts)
        if !matchedAutomations.isEmpty {
            log.info("Automation evaluation matched \(matchedAutomations.count) rule(s)")
            await fireMatchedAutomations(matches: matchedAutomations, config: &config)
        }

        // daily digest check
        guard !Task.isCancelled else { return }
        checkDailyDigest(config: config, accounts: activeAccounts)

        NotificationCenter.default.post(
            name: .usageDidUpdate,
            object: nil,
            userInfo: ["accountIds": updatedIds]
        )
        if await consumePendingLogRefresh() {
            await scheduleDebouncedLogRefresh()
        }
    }

    internal func fetchAndStore(account: Account, config: Config) async {
        guard !Task.isCancelled else { return }
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
                await MainActor.run { self.lastFetchError = msg }
            } catch APIError.rateLimited(let retryAfter) {
                let msg = "Rate limited for account \(account.id.uuidString); retry after \(retryAfter ?? 0)s"
                ErrorLogger.shared.log(msg, file: #file, line: #line)
                await MainActor.run { self.lastFetchError = msg }
            } catch APIError.networkError(let underlying) {
                let msg = "Network error for account \(account.id.uuidString): \(underlying.localizedDescription)"
                ErrorLogger.shared.log(msg, file: #file, line: #line)
                await MainActor.run { self.lastFetchError = msg }
            } catch {
                let msg = "Unexpected error for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(msg, file: #file, line: #line)
                await MainActor.run { self.lastFetchError = msg }
            }
            await MainActor.run { self.lastFetchError = nil } // clear on successful fetch
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

    private func checkThresholds(config: Config, accounts: [Account]) {
        for account in accounts {
            guard let limit = account.costLimitUSD else { continue }
            let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
            let snapshot = UsageSnapshot(
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
            NotificationManager.shared.checkThreshold(
                snapshot: snapshot,
                account: account,
                limitUSD: limit,
                webhookConfig: config.webhook
            )
        }
    }

    private func evaluateAutomations(config: Config, accounts: [Account]) -> [(AutomationRule, UsageSnapshot)] {
        var matched: [(AutomationRule, UsageSnapshot)] = []
        for account in accounts {
            let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
            let snapshot = UsageSnapshot(
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
            let triggered = AutomationEngine.evaluate(rules: config.automations, snapshot: snapshot)
            for rule in triggered where Self.isAutomationOffCooldown(rule, pollIntervalSeconds: config.pollIntervalSeconds) {
                matched.append((rule, snapshot))
            }
        }
        return matched
    }

    private func fireMatchedAutomations(matches: [(AutomationRule, UsageSnapshot)], config: inout Config) async {
        var didMutateConfig = false
        for (rule, snapshot) in matches {
            let fired = await AutomationEngine.fire(rule: rule, snapshot: snapshot)
            guard fired else { continue }
            if let idx = config.automations.firstIndex(where: { $0.id == rule.id }) {
                config.automations[idx].lastFiredAt = Date()
                didMutateConfig = true
            }
        }
        if didMutateConfig {
            ConfigManager.shared.save(config)
        }
    }

    static func isAutomationOffCooldown(_ rule: AutomationRule, pollIntervalSeconds: Int, now: Date = Date()) -> Bool {
        guard let lastFiredAt = rule.lastFiredAt else { return true }
        let cooldown = max(1, pollIntervalSeconds)
        return now.timeIntervalSince(lastFiredAt) >= TimeInterval(cooldown)
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

    private func scheduleDebouncedLogRefresh(delayNanos: UInt64 = 400_000_000) async {
        await MainActor.run {
            self.logChangeDebounceTask?.cancel()
            self.logChangeDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNanos)
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
                await MainActor.run { self.logChangeDebounceTask = nil }
            }
        }
    }

    private func consumePendingLogRefresh() async -> Bool {
        await MainActor.run {
            let pending = self.pendingLogRefresh
            self.pendingLogRefresh = false
            return pending
        }
    }
}

extension Notification.Name {
    static let usageDidUpdate = Notification.Name("UsageDidUpdate")
    static let claudeAISessionExpired = Notification.Name("ClaudeAISessionExpired")
}
