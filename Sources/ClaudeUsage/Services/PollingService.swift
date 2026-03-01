import Foundation
import Combine
import Network
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "PollingService")

class PollingService: ObservableObject {
    static let shared = PollingService()
    static var anthropicClientFactory: (String) -> AnthropicAPIClient = { apiKey in
        AnthropicAPIClient(apiKey: apiKey)
    }
    @MainActor @Published var lastPollDate: Date?
    @MainActor @Published var isPolling: Bool = false
    @MainActor @Published var lastFetchError: String?
    @MainActor @Published var lastPollSuccessCount: Int = 0
    @MainActor @Published var lastPollFailureCount: Int = 0

    private var timer: Timer?
    private var currentTask: Task<Void, Never>?
    @MainActor private var currentPollToken: UUID?
    private let maxConcurrencyUpperCap = 6
    private let pathMonitor = NWPathMonitor()
    @MainActor private var networkAvailable = true
    @MainActor private var pendingLogRefresh = false
    @MainActor private var logChangeDebounceTask: Task<Void, Never>?
    @MainActor private var fetchErrorsByAccount: [UUID: String] = [:]
    @MainActor private var fetchErrorUpdatedAtByAccount: [UUID: Date] = [:]
    @MainActor private var consecutiveFetchFailuresByAccount: [UUID: Int] = [:]
    @MainActor private var recentFetchOutcomesByAccount: [UUID: [Bool]] = [:]
    private let failureDisableThreshold = 5
    private let healthWindowSize = 20

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
                if !updatedIds.isEmpty {
                    self.lastPollDate = Date()
                }
                log.info("Poll completed")
            }
        }

        let activeAccounts = config.accounts.filter { $0.isActive }
        let concurrencyLimit = min(max(1, activeAccounts.count), maxConcurrencyUpperCap)
        var updatedIds: [UUID] = []

        await withTaskGroup(of: UUID?.self) { group in
            var launched = 0
            for account in activeAccounts {
                if launched >= concurrencyLimit { _ = await group.next() }
                group.addTask { [account] in
                    guard !Task.isCancelled else { return nil }
                    let jitter = self.accountPollJitterNanos(accountId: account.id, activeAccountCount: activeAccounts.count)
                    if jitter > 0 {
                        try? await Task.sleep(nanoseconds: jitter)
                    }
                    await self.fetchAndStore(account: account, config: config)
                    let hasError = await MainActor.run {
                        self.fetchErrorsByAccount[account.id] != nil
                    }
                    return hasError ? nil : account.id
                }
                launched += 1
            }
            for await id in group {
                if let id { updatedIds.append(id) }
            }
        }
        let failures = max(0, activeAccounts.count - updatedIds.count)
        await MainActor.run {
            self.lastPollSuccessCount = updatedIds.count
            self.lastPollFailureCount = failures
        }

        // compute forecasts
        for account in activeAccounts {
            guard !Task.isCancelled else { return }
            let history = await CacheManager.shared.historyAsync(forAccount: account.id, days: 1)
            if let forecast = ForecastEngine.compute(history: history) {
                await CacheManager.shared.saveForecastAsync(forecast)
            }
        }

        // generate model hints for popover
        await generateAndPersistModelHints(config: config, accounts: activeAccounts)

        // iCloud sync if enabled
        if config.iCloudSync.enabled {
            await iCloudSyncManager.shared.syncNow()
        }

        // threshold notifications
        guard !Task.isCancelled else { return }
        await checkThresholds(config: config, accounts: activeAccounts)

        // automation evaluation
        let matchedAutomations = await evaluateAutomations(config: config, accounts: activeAccounts)
        if !matchedAutomations.isEmpty {
            log.info("Automation evaluation matched \(matchedAutomations.count) rule(s)")
            await fireMatchedAutomations(matches: matchedAutomations, config: &config)
        }

        // daily digest check
        guard !Task.isCancelled else { return }
        await checkDailyDigest(config: config, accounts: activeAccounts)

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
        let accountID = account.id.uuidString
        let providerType = account.type.rawValue
        func withProviderContext(_ message: String) -> String {
            "[account_id=\(accountID)] [provider_type=\(providerType)] \(message)"
        }
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
            await CacheManager.shared.appendAsync(snap)
            await clearFetchError(for: account.id)
        case .codex:
            var snap = CodexLogParser.shared.aggregateToday()
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
            await CacheManager.shared.appendAsync(snap)
            await clearFetchError(for: account.id)
        case .gemini:
            var snap = GeminiLogParser.shared.aggregateToday()
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
            await CacheManager.shared.appendAsync(snap)
            await clearFetchError(for: account.id)
        case .openAIOrg:
            let rawCredential: String
            do {
                rawCredential = try KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString)
            } catch {
                let msg = "No OpenAI admin key for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg))
                await setFetchError(msg, for: account.id)
                return
            }
            guard let adminKey = ProviderCredentialCodec.openAIAdminKey(from: rawCredential) else {
                let msg = "Invalid OpenAI credential payload for account \(account.id.uuidString)"
                ErrorLogger.shared.log(withProviderContext(msg))
                await setFetchError(msg, for: account.id)
                return
            }
            do {
                let client = OpenAIOrgUsageClient(adminAPIKey: adminKey)
                let snap = try await client.fetchCurrentSnapshot(accountId: account.id)
                await CacheManager.shared.appendAsync(snap)
                await clearFetchError(for: account.id)
            } catch APIError.invalidKey {
                let msg = "Invalid OpenAI admin key for account \(account.id.uuidString)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch APIError.rateLimited(let retryAfter) {
                let wait = max(1, retryAfter ?? 60)
                let msg = "OpenAI usage API rate-limited for account \(account.id.uuidString); retry after \(wait)s"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch APIError.networkError(let underlying) {
                let msg = "OpenAI usage API network error for account \(account.id.uuidString): \(underlying.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch {
                let msg = "OpenAI usage API unexpected error for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            }
        case .windsurfEnterprise:
            let rawCredential: String
            do {
                rawCredential = try KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString)
            } catch {
                let msg = "No Windsurf service key for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg))
                await setFetchError(msg, for: account.id)
                return
            }
            guard let payload = ProviderCredentialCodec.windsurf(from: rawCredential) else {
                let msg = "Invalid Windsurf credential payload for account \(account.id.uuidString)"
                ErrorLogger.shared.log(withProviderContext(msg))
                await setFetchError(msg, for: account.id)
                return
            }
            do {
                let client = WindsurfEnterpriseClient(serviceKey: payload.serviceKey, groupName: payload.groupName)
                let snap = try await client.fetchCurrentSnapshot(accountId: account.id)
                await CacheManager.shared.appendAsync(snap)
                await clearFetchError(for: account.id)
            } catch APIError.invalidKey {
                let msg = "Invalid Windsurf service key for account \(account.id.uuidString)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch APIError.rateLimited(let retryAfter) {
                let wait = max(1, retryAfter ?? 60)
                let msg = "Windsurf API rate-limited for account \(account.id.uuidString); retry after \(wait)s"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch APIError.networkError(let underlying) {
                let msg = "Windsurf API network error for account \(account.id.uuidString): \(underlying.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch {
                let msg = "Windsurf API unexpected error for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            }
        case .githubCopilot:
            let rawCredential: String
            do {
                rawCredential = try KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString)
            } catch {
                let msg = "No GitHub token for Copilot account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg))
                await setFetchError(msg, for: account.id)
                return
            }
            guard let payload = ProviderCredentialCodec.copilot(from: rawCredential) else {
                let msg = "Invalid GitHub Copilot credential payload for account \(account.id.uuidString)"
                ErrorLogger.shared.log(withProviderContext(msg))
                await setFetchError(msg, for: account.id)
                return
            }
            do {
                let client = GitHubCopilotMetricsClient(token: payload.token, organization: payload.organization)
                let snap = try await client.fetchCurrentSnapshot(accountId: account.id)
                await CacheManager.shared.appendAsync(snap)
                await clearFetchError(for: account.id)
            } catch APIError.invalidKey {
                let msg = "Invalid GitHub token/permissions for Copilot account \(account.id.uuidString)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch APIError.rateLimited(let retryAfter) {
                let wait = max(1, retryAfter ?? 60)
                let msg = "GitHub Copilot metrics API rate-limited for account \(account.id.uuidString); retry after \(wait)s"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch APIError.networkError(let underlying) {
                let msg = "GitHub Copilot metrics API network error for account \(account.id.uuidString): \(underlying.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch {
                let msg = "GitHub Copilot metrics API unexpected error for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            }
        case .anthropicAPI:
            let key: String
            do {
                key = try KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString)
            } catch {
                let msg = "Keychain failure for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg))
                await setFetchError(msg, for: account.id)
                return
            }
            if let retryAfter = await CacheManager.shared.loadAnthropicRetryAfterAsync(forAccount: account.id), retryAfter > Date() {
                let seconds = Int(retryAfter.timeIntervalSinceNow.rounded(.up))
                let msg = "Rate limited for account \(account.id.uuidString); deferred for \(max(1, seconds))s"
                log.warning("\(msg, privacy: .public)")
                await setFetchError(msg, for: account.id)
                return
            }
            do {
                // Anthropic Usage API remains the canonical billing source for anthropicAPI accounts.
                let result = try await fetchAnthropicCanonicalSnapshots(accountId: account.id, apiKey: key)
                let snapshots = result.snapshots
                await CacheManager.shared.upsertAnthropicSnapshotsAsync(snapshots, forAccount: account.id)
                if let cursor = result.cursor {
                    await CacheManager.shared.saveAnthropicCursorAsync(cursor, forAccount: account.id)
                }
                await CacheManager.shared.clearAnthropicRetryAfterAsync(forAccount: account.id)
                await clearFetchError(for: account.id)
            } catch APIError.invalidKey {
                let msg = "Invalid API key for account \(account.id.uuidString)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch APIError.rateLimited(let retryAfter) {
                let retryDate = Self.retryAfterDate(fromSeconds: retryAfter)
                let retrySeconds = Int(retryDate.timeIntervalSinceNow.rounded(.up))
                await CacheManager.shared.saveAnthropicRetryAfterAsync(retryDate, forAccount: account.id)
                let msg = "Rate limited for account \(account.id.uuidString); retry after \(max(1, retrySeconds))s"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch APIError.networkError(let underlying) {
                let msg = "Network error for account \(account.id.uuidString): \(underlying.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            } catch {
                let msg = "Unexpected error for account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg), file: #file, line: #line)
                await setFetchError(msg, for: account.id)
            }
        case .claudeAI:
            let token: String
            do {
                token = try KeychainManager.retrieve(service: AppConstants.keychainSessionTokenService, account: account.id.uuidString)
            } catch {
                let msg = "No session token for claudeAI account \(account.id.uuidString): \(error.localizedDescription)"
                ErrorLogger.shared.log(withProviderContext(msg))
                await setFetchError(msg, for: account.id)
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
                await CacheManager.shared.appendAsync(snap)
                await clearFetchError(for: account.id)
            } else {
                let msg = "claudeAI fetchUsage returned nil for account \(account.id.uuidString) — using cached snapshot"
                ErrorLogger.shared.log(withProviderContext(msg), level: "WARN")
                await setFetchError(msg, for: account.id)
                if var cached = await CacheManager.shared.latestAsync(forAccount: account.id) {
                    cached.isStale = true
                    cached.timestamp = Date()
                    cached.costConfidence = .estimated
                    await CacheManager.shared.appendAsync(cached)
                }
                NotificationCenter.default.post(name: .claudeAISessionExpired, object: account.id)
            }
        }
    }

    private func checkDailyDigest(config: Config, accounts: [Account]) async {
        guard config.webhook.enabled, config.webhook.events.contains("daily_digest") else { return }
        let key = "lastDailyDigestDate"
        let cal = Calendar.current
        if let prev = UserDefaults.standard.object(forKey: key) as? Date,
           cal.isDateInToday(prev) { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let ws = WebhookService()
        for account in accounts {
            let agg = await CacheManager.shared.todayAggregateAsync(forAccount: account.id)
            let snap = UsageSnapshot(
                accountId: account.id,
                timestamp: Date(),
                inputTokens: agg.totalInputTokens,
                outputTokens: agg.totalOutputTokens,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                totalCostUSD: agg.totalCostUSD,
                modelBreakdown: [],
                costConfidence: Self.isBillingGradeAccountType(account.type) ? .billingGrade : .estimated
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

    private func checkThresholds(config: Config, accounts: [Account]) async {
        for account in accounts {
            guard let limit = account.costLimitUSD else { continue }
            let agg = await CacheManager.shared.todayAggregateAsync(forAccount: account.id)
            let snapshot = UsageSnapshot(
                accountId: account.id,
                timestamp: Date(),
                inputTokens: agg.totalInputTokens,
                outputTokens: agg.totalOutputTokens,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                totalCostUSD: agg.totalCostUSD,
                modelBreakdown: [],
                costConfidence: Self.isBillingGradeAccountType(account.type) ? .billingGrade : .estimated
            )
            NotificationManager.shared.checkThreshold(
                snapshot: snapshot,
                account: account,
                limitUSD: limit,
                webhookConfig: config.webhook
            )
        }
    }

    private func evaluateAutomations(config: Config, accounts: [Account]) async -> [(AutomationRule, UsageSnapshot)] {
        var matched: [(AutomationRule, UsageSnapshot)] = []
        for account in accounts {
            let agg = await CacheManager.shared.todayAggregateAsync(forAccount: account.id)
            let snapshot = UsageSnapshot(
                accountId: account.id,
                timestamp: Date(),
                inputTokens: agg.totalInputTokens,
                outputTokens: agg.totalOutputTokens,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                totalCostUSD: agg.totalCostUSD,
                modelBreakdown: [],
                costConfidence: Self.isBillingGradeAccountType(account.type) ? .billingGrade : .estimated
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
            if case .failure(let error) = ConfigManager.shared.save(config) {
                ErrorLogger.shared.log("Failed to persist automation fire state: \(error)")
            }
        }
    }

    static func isAutomationOffCooldown(_ rule: AutomationRule, pollIntervalSeconds: Int, now: Date = Date()) -> Bool {
        guard let lastFiredAt = rule.lastFiredAt else { return true }
        let cooldown = max(1, pollIntervalSeconds)
        return now.timeIntervalSince(lastFiredAt) >= TimeInterval(cooldown)
    }

    private static func isBillingGradeAccountType(_ type: AccountType) -> Bool {
        type == .anthropicAPI || type == .openAIOrg
    }

    private func fetchAnthropicCanonicalSnapshots(accountId: UUID, apiKey: String) async throws -> (snapshots: [UsageSnapshot], cursor: AnthropicIngestionCursor?) {
        let client = Self.anthropicClientFactory(apiKey)
        let end = Date()
        let cursor = await CacheManager.shared.loadAnthropicCursorAsync(forAccount: accountId)
        let start = Self.anthropicStartDate(cursor: cursor, now: end)
        let response = try await fetchAnthropicUsageWithRetry(
            client: client,
            accountId: accountId,
            startDate: start,
            endDate: end
        )
        return (client.convertToSnapshots(response, accountId: accountId), client.cursor(from: response))
    }

    static func anthropicStartDate(cursor: AnthropicIngestionCursor?, now: Date = Date()) -> Date {
        let fallback = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        guard let raw = cursor?.lastStartTime else { return fallback }
        guard let ts = SharedDateFormatters.iso8601InternetDateTime.date(from: raw)
            ?? SharedDateFormatters.iso8601InternetDateTimeFractional.date(from: raw) else { return fallback }
        return Calendar.current.startOfDay(for: ts)
    }

    internal func generateAndPersistModelHints(config: Config, accounts: [Account]) async {
        let hints: [ModelHint]
        if config.modelOptimizer.enabled {
            var computed: [ModelHint] = []
            for account in accounts {
                guard let latest = await CacheManager.shared.latestAsync(forAccount: account.id) else { continue }
                if let hint = ModelOptimizerAnalyzer.analyze(
                    breakdown: latest.modelBreakdown,
                    accountId: account.id,
                    config: config.modelOptimizer
                ) {
                    computed.append(hint)
                }
            }
            hints = computed
        } else {
            hints = []
        }
        let url = AppConstants.sharedContainerURL.appendingPathComponent("model_hints.json")
        do {
            try FileManager.default.createDirectory(
                at: AppConstants.sharedContainerURL,
                withIntermediateDirectories: true
            )
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(hints)
            try data.write(to: url, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Failed to persist model hints: \(error.localizedDescription)")
        }
    }

    private func fetchAnthropicUsageWithRetry(
        client: AnthropicAPIClient,
        accountId: UUID,
        startDate: Date,
        endDate: Date,
        maxAttempts: Int = 4
    ) async throws -> AnthropicUsageResponse {
        precondition(maxAttempts >= 1)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await client.fetchUsage(startDate: startDate, endDate: endDate)
            } catch APIError.rateLimited(let retryAfter) where attempt < maxAttempts - 1 {
                let delay = Self.jitteredBackoffDelayNanos(attempt: attempt, retryAfterSeconds: retryAfter)
                log.warning("Anthropic rate-limited for \(accountId.uuidString), retrying in \(Double(delay) / 1_000_000_000, format: .fixed(precision: 2))s")
                try await Task.sleep(nanoseconds: delay)
                attempt += 1
            } catch APIError.serverError(let code) where (500...599).contains(code) && attempt < maxAttempts - 1 {
                let delay = Self.jitteredBackoffDelayNanos(attempt: attempt, retryAfterSeconds: nil)
                log.warning("Anthropic 5xx (\(code)) for \(accountId.uuidString), retrying in \(Double(delay) / 1_000_000_000, format: .fixed(precision: 2))s")
                try await Task.sleep(nanoseconds: delay)
                attempt += 1
            } catch {
                throw error
            }
        }
    }

    private static func jitteredBackoffDelayNanos(attempt: Int, retryAfterSeconds: Int?) -> UInt64 {
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            let base = Double(retryAfterSeconds)
            let jitter = Double.random(in: 0...(base * 0.25))
            return UInt64((base + jitter) * 1_000_000_000)
        }
        let exponent = min(attempt, 5)
        let base = pow(2.0, Double(exponent))
        let jitter = Double.random(in: 0...(base * 0.35))
        return UInt64((base + jitter) * 1_000_000_000)
    }

    private static func retryAfterDate(fromSeconds retryAfterSeconds: Int?) -> Date {
        let fallbackSeconds = 60
        let raw = retryAfterSeconds ?? fallbackSeconds
        let clamped = max(1, min(raw, 3600))
        return Date().addingTimeInterval(TimeInterval(clamped))
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

    private func accountPollJitterNanos(accountId: UUID, activeAccountCount: Int) -> UInt64 {
        guard activeAccountCount > 1 else { return 0 }
        let hash = accountId.uuidString.utf8.reduce(UInt64(0)) { ($0 &* 33) &+ UInt64($1) }
        let jitterMillis = hash % 350
        return jitterMillis * 1_000_000
    }

    private func setFetchError(_ message: String, for accountId: UUID) async {
        await recordFetchOutcome(success: false, for: accountId)
        let shouldDisable = await MainActor.run {
            let newFailureCount = (self.consecutiveFetchFailuresByAccount[accountId] ?? 0) + 1
            self.consecutiveFetchFailuresByAccount[accountId] = newFailureCount
            self.fetchErrorsByAccount[accountId] = message
            self.fetchErrorUpdatedAtByAccount[accountId] = Date()
            self.refreshLastFetchErrorSummary()
            return newFailureCount >= self.failureDisableThreshold
        }
        if shouldDisable {
            await disableAccountAfterRepeatedFailures(accountId: accountId)
        }
    }

    private func clearFetchError(for accountId: UUID) async {
        await recordFetchOutcome(success: true, for: accountId)
        await CacheManager.shared.saveLastSuccessAsync(Date(), forAccount: accountId)
        await MainActor.run {
            self.fetchErrorsByAccount.removeValue(forKey: accountId)
            self.fetchErrorUpdatedAtByAccount.removeValue(forKey: accountId)
            self.consecutiveFetchFailuresByAccount.removeValue(forKey: accountId)
            self.refreshLastFetchErrorSummary()
        }
    }

    private func recordFetchOutcome(success: Bool, for accountId: UUID) async {
        await MainActor.run {
            var outcomes = self.recentFetchOutcomesByAccount[accountId] ?? []
            outcomes.append(success)
            if outcomes.count > self.healthWindowSize {
                outcomes.removeFirst(outcomes.count - self.healthWindowSize)
            }
            self.recentFetchOutcomesByAccount[accountId] = outcomes
        }
    }

    @MainActor
    func providerHealthScore(for accountId: UUID) -> Double? {
        guard let outcomes = recentFetchOutcomesByAccount[accountId], !outcomes.isEmpty else { return nil }
        let successCount = outcomes.filter { $0 }.count
        return Double(successCount) / Double(outcomes.count)
    }

    private func disableAccountAfterRepeatedFailures(accountId: UUID) async {
        var config = ConfigManager.shared.load()
        guard let index = config.accounts.firstIndex(where: { $0.id == accountId && $0.isActive }) else { return }
        config.accounts[index].isActive = false
        if case .failure(let error) = ConfigManager.shared.save(config) {
            ErrorLogger.shared.log("Failed to persist auto-disabled account state: \(error)")
            return
        }
        let message = "Auto-disabled account \(accountId.uuidString) after \(failureDisableThreshold) consecutive fetch failures; re-enable manually in Settings."
        ErrorLogger.shared.log(message, level: "WARN")
        await MainActor.run {
            self.fetchErrorsByAccount[accountId] = message
            self.fetchErrorUpdatedAtByAccount[accountId] = Date()
            self.refreshLastFetchErrorSummary()
        }
    }

    @MainActor
    private func refreshLastFetchErrorSummary() {
        guard let latestAccountId = fetchErrorUpdatedAtByAccount.max(by: { $0.value < $1.value })?.key else {
            lastFetchError = nil
            return
        }
        lastFetchError = fetchErrorsByAccount[latestAccountId]
    }
}

extension Notification.Name {
    static let usageDidUpdate = Notification.Name("UsageDidUpdate")
    static let claudeAISessionExpired = Notification.Name("ClaudeAISessionExpired")
}
