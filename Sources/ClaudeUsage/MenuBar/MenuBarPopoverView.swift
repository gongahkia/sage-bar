import SwiftUI
import Charts

struct MenuBarPopoverView: View {
    private let selectedAccountDefaultsKey = "menubarSelectedAccountID"
    @State private var config = ConfigManager.shared.load()
    @State private var selectedAccountIndex = 0
    @State private var showHistory = false
    @State private var needsReAuth: Bool = false
    @State private var showModelBreakdown = false
    @State private var copyFeedback = false
    @StateObject private var viewModel = ViewModel()
    @ObservedObject private var polling = PollingService.shared
    @ObservedObject private var errorLogger = ErrorLogger.shared

    private struct AccountMetrics {
        let latestSnapshot: UsageSnapshot?
        let todayAggregate: DailyAggregate
        let latestForecast: ForecastSnapshot?
        let weekSnapshots: [UsageSnapshot]
        let daySnapshots: [UsageSnapshot]
        let modelHint: ModelHint?
    }

    @MainActor
    private final class ViewModel: ObservableObject {
        private actor ModelHintsMemoStore {
            private var cachedHints: [ModelHint]?

            func hint(for accountId: UUID) -> ModelHint? {
                if cachedHints == nil {
                    let url = AppConstants.sharedContainerURL.appendingPathComponent("model_hints.json")
                    if let data = try? Data(contentsOf: url),
                       let hints = try? JSONDecoder().decode([ModelHint].self, from: data) {
                        cachedHints = hints
                    } else {
                        cachedHints = []
                    }
                }
                return cachedHints?.first(where: { $0.accountId == accountId && $0.cheaperAlternativeExists })
            }

            func invalidate() {
                cachedHints = nil
            }
        }

        private nonisolated static let modelHintsMemo = ModelHintsMemoStore()
        @Published private(set) var metricsByAccount: [UUID: AccountMetrics] = [:]
        private var inflightLoads: [UUID: Task<Void, Never>] = [:]

        func metrics(for accountId: UUID) -> AccountMetrics? {
            metricsByAccount[accountId]
        }

        func load(account: Account) {
            inflightLoads[account.id]?.cancel()
            inflightLoads[account.id] = Task { [weak self] in
                let loaded = await Self.fetchMetricsOffMain(account: account)
                guard !Task.isCancelled else { return }
                self?.metricsByAccount[account.id] = loaded
            }
        }

        func invalidateModelHintsCache() {
            Task { await Self.modelHintsMemo.invalidate() }
        }

        private static func fetchMetricsOffMain(account: Account) async -> AccountMetrics {
            await Task.detached(priority: .utility) {
                async let latestSnapshot = CacheManager.shared.latestAsync(forAccount: account.id)
                async let todayAggregate = CacheManager.shared.todayAggregateAsync(forAccount: account.id)
                async let latestForecast = CacheManager.shared.latestForecastAsync(forAccount: account.id)
                async let weekSnapshots = CacheManager.shared.historyAsync(forAccount: account.id, days: 7)
                async let daySnapshots = CacheManager.shared.historyAsync(forAccount: account.id, days: 1)
                let modelHint = await Self.modelHintsMemo.hint(for: account.id)
                return await AccountMetrics(
                    latestSnapshot: latestSnapshot,
                    todayAggregate: todayAggregate,
                    latestForecast: latestForecast,
                    weekSnapshots: weekSnapshots,
                    daySnapshots: daySnapshots,
                    modelHint: modelHint
                )
            }.value
        }
    }

    private var activeAccounts: [Account] {
        config.accounts
            .filter { $0.isActive }
            .sorted {
                if $0.order == $1.order { return $0.createdAt < $1.createdAt }
                return $0.order < $1.order
            }
    }
    private var currentAccount: Account? { activeAccounts.indices.contains(selectedAccountIndex) ? activeAccounts[selectedAccountIndex] : activeAccounts.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if activeAccounts.count > 1 {
                accountPicker
            }
            if let account = currentAccount {
                let metrics = viewModel.metrics(for: account.id)
                accountFetchLabel(account: account, metrics: metrics) // task 78: per-account relative last-fetch
                if needsReAuth && account.type == .claudeAI {
                    reAuthBanner
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if account.type == .claudeAI {
                            claudeAIStatsSection(account: account, metrics: metrics)
                        } else {
                            todayStatsSection(account: account, metrics: metrics)
                            modelBreakdownSection(metrics: metrics) // task 77
                        }
                        if account.type != .claudeAI && config.forecast.showInPopover && config.forecast.enabled {
                            forecastSection(metrics: metrics)
                        }
                        if account.type != .claudeAI {
                            chartSection(metrics: metrics)
                        }
                        if let hint = metrics?.modelHint,
                           config.modelOptimizer.enabled && config.modelOptimizer.showInPopover {
                            modelHintBanner(hint: hint, account: account)
                        }
                        pollHealthRow(metrics: metrics)
                    }
                }
            }
            Divider()
            if let err = errorLogger.lastError { lastErrorBanner(err) }
            footer
        }
        .frame(width: 340)
        .sheet(isPresented: $showHistory) {
            HistoryView(account: currentAccount)
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeAISessionExpired)) { _ in
            needsReAuth = true
        }
        .onAppear {
            restoreSelectedAccountIndex()
            refreshCurrentAccountMetrics()
        }
        .onChange(of: selectedAccountIndex) { newValue in
            guard activeAccounts.indices.contains(newValue) else { return }
            UserDefaults.standard.set(activeAccounts[newValue].id.uuidString, forKey: selectedAccountDefaultsKey)
            refreshCurrentAccountMetrics()
        }
        .onChange(of: activeAccounts.map(\.id)) { _ in
            restoreSelectedAccountIndex()
            refreshCurrentAccountMetrics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageDidUpdate)) { _ in
            viewModel.invalidateModelHintsCache()
            refreshCurrentAccountMetrics()
        }
    }

    // MARK: – Header
    private var header: some View {
        HStack {
            Text("Sage Bar").font(.headline)
            if polling.lastPollFailureCount > 0 {
                let partial = polling.lastPollSuccessCount > 0
                Text(partial ? "Partial" : "Failed")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((partial ? Color.orange : Color.red).opacity(0.18))
                    .foregroundColor(partial ? .orange : .red)
                    .clipShape(Capsule())
            }
            Spacer()
            if polling.isPolling { ProgressView().scaleEffect(0.6) }
            if let date = polling.lastPollDate {
                Text(date, style: .relative).font(.caption).foregroundColor(.secondary)
                Text("ago").font(.caption).foregroundColor(.secondary)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: – Account picker
    private var accountPicker: some View {
        Picker("", selection: $selectedAccountIndex) {
            ForEach(activeAccounts.indices, id: \.self) { i in
                Text(displayName(for: activeAccounts[i])).tag(i)
            }
        }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: – Today stats
    private func todayStatsSection(account: Account, metrics: AccountMetrics?) -> some View {
        let agg = metrics?.todayAggregate ?? DailyAggregate(
            date: Calendar.current.dateComponents([.year, .month, .day], from: Date()),
            snapshots: []
        )
        let confidence = currentCostConfidence(account: account, latestSnapshot: metrics?.latestSnapshot)
        return VStack(alignment: .leading, spacing: 4) {
            statRow("Input Tokens", value: "\(agg.totalInputTokens.formatted())")
            statRow("Output Tokens", value: "\(agg.totalOutputTokens.formatted())")
            statRow("Cache Tokens", value: "\((agg.snapshots.reduce(0) { $0 + $1.cacheReadTokens + $1.cacheCreationTokens }).formatted())")
            statRow("Cost Today", value: String(format: "$%.4f", agg.totalCostUSD))
            burnRateStatusRows(account: account, metrics: metrics)
            confidenceRow(confidence)
        }.padding(12)
    }

    // MARK: – Forecast
    private func forecastSection(metrics: AccountMetrics?) -> some View {
        Group {
            if let f = metrics?.latestForecast {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Projected Spend", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption).foregroundColor(.secondary)
                    statRow("EOD", value: String(format: "$%.2f", f.projectedEODCostUSD))
                    statRow("EOW", value: String(format: "$%.2f", f.projectedEOWCostUSD))
                    statRow("EOM", value: String(format: "$%.2f", f.projectedEOMCostUSD))
                }.padding(.horizontal, 12).padding(.bottom, 8)
            } else {
                Text("Not enough data yet").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    // MARK: – 7-day chart
    private func chartSection(metrics: AccountMetrics?) -> some View {
        let snaps = metrics?.weekSnapshots ?? []
        let cal = Calendar.current
        let byDay: [(Date, Double)] = Dictionary(grouping: snaps, by: {
            cal.startOfDay(for: $0.timestamp)
        }).map { ($0.key, $0.value.reduce(0) { $0 + $1.totalCostUSD }) }
        .sorted { $0.0 < $1.0 }
        return Group {
            if !byDay.isEmpty {
                Chart(byDay, id: \.0) { d in
                    BarMark(x: .value("Day", d.0, unit: .day), y: .value("Cost", d.1))
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisTick(); AxisGridLine() } }
                .frame(height: 80).padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    // MARK: – Model hint banner

    private func modelHintBanner(hint: ModelHint, account: Account) -> some View {
        let dismissKey = "modelHintDismissed_\(account.id.uuidString)"
        let dismissed = UserDefaults.standard.object(forKey: dismissKey) as? Date
        let shouldShow = dismissed.map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true
        let provider = hintProviderName(hint: hint, account: account)
        let confidence = hintConfidenceLabel(hint.savingsConfidence)
        return Group {
            if shouldShow {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "lightbulb").foregroundColor(.yellow)
                        Text("\(provider) model recommendation")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button(action: { UserDefaults.standard.set(Date(), forKey: dismissKey) }) {
                            Image(systemName: "xmark").font(.caption2)
                        }.buttonStyle(.plain)
                    }
                    Text("↓ ~\(String(format: "$%.2f", hint.estimatedSavingsUSD))/day switching to \(hint.recommendedModel)")
                        .font(.caption)
                    Text("Confidence: \(confidence)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.yellow.opacity(0.1)).cornerRadius(6).padding(.horizontal, 12)
            }
        }
    }

    // MARK: – Poll health
    private func pollHealthRow(metrics: AccountMetrics?) -> some View {
        let staleMultiplier = 2.0
        return VStack(alignment: .leading, spacing: 2) {
            if let latest = metrics?.latestSnapshot {
                let ageSeconds = max(0, Date().timeIntervalSince(latest.timestamp))
                let thresholdSeconds = Double(config.pollIntervalSeconds) * staleMultiplier
                let staleByAge = ageSeconds > thresholdSeconds
                let isStale = latest.isStale || staleByAge
                let ageMinutes = Int((ageSeconds / 60.0).rounded())
                let thresholdMinutes = max(1, Int((thresholdSeconds / 60.0).rounded()))
                statRow("Data age", value: "\(ageMinutes)m" + (isStale ? " (stale)" : ""))
                statRow("Stale after", value: "\(thresholdMinutes)m (\(Int(staleMultiplier))x poll)")
            }
            if let last = polling.lastPollDate {
                statRow("Last synced", value: last.formatted(.relative(presentation: .named)))
                let next = last.addingTimeInterval(TimeInterval(config.pollIntervalSeconds))
                statRow("Next poll", value: next.formatted(.relative(presentation: .named)))
            } else {
                statRow("Last synced", value: "Never")
            }
        }.padding(.horizontal, 12).padding(.bottom, 6)
    }

    // MARK: – ClaudeAI stats
    private func claudeAIStatsSection(account: Account, metrics: AccountMetrics?) -> some View {
        let remaining = metrics?.latestSnapshot?.modelBreakdown.first(where: { $0.modelId == "claude-ai-web" })?.inputTokens
        return VStack(alignment: .leading, spacing: 4) {
            if let r = remaining {
                statRow("Messages remaining", value: "\(r)")
            } else {
                Text("No data yet").font(.caption).foregroundColor(.secondary)
            }
            confidenceRow(currentCostConfidence(account: account, latestSnapshot: metrics?.latestSnapshot))
        }.padding(12)
    }

    private func currentCostConfidence(account: Account, latestSnapshot: UsageSnapshot?) -> String {
        if let latest = latestSnapshot {
            return latest.costConfidence == .billingGrade ? "Billing-grade" : "Estimated"
        }
        return (account.type == .anthropicAPI || account.type == .openAIOrg) ? "Billing-grade" : "Estimated"
    }

    // MARK: – Re-auth banner
    private var reAuthBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill").foregroundColor(.orange)
            Text("claude.ai session expired — update your session token in Settings.")
                .font(.caption).lineLimit(2)
            Spacer()
            Button { needsReAuth = false } label: {
                Image(systemName: "xmark").font(.caption2)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }

    // MARK: – Last Error
    private func lastErrorBanner(_ err: AppError) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(err.message).font(.caption).lineLimit(2)
                Text(err.timestamp, style: .relative).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button { errorLogger.lastError = nil } label: {
                Image(systemName: "xmark").font(.caption2)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.red.opacity(0.1))
    }

    // MARK: – Footer
    private var footer: some View {
        HStack {
            Button("Refresh Now") { PollingService.shared.forceRefresh() }
                .buttonStyle(.plain).font(.caption)
                .keyboardShortcut("r", modifiers: .command) // task 79: Cmd+R
            Button(copyFeedback ? "Copied" : "Copy Totals") {
                copyActiveAccountDailyTotals()
                copyFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copyFeedback = false }
            }
            .buttonStyle(.plain).font(.caption)
            Button("Copy Account Info") {
                copyActiveAccountDebugInfo()
            }
            .buttonStyle(.plain).font(.caption)
            Spacer()
            if config.analytics.enabled {
                Button("History") { showHistory = true }.buttonStyle(.plain).font(.caption)
            }
            Button("Settings…") {
                SettingsWindowController.shared.showWindow()
            }.buttonStyle(.plain).font(.caption)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: – Task 78: per-account last-fetch label

    private func accountFetchLabel(account: Account, metrics: AccountMetrics?) -> some View {
        Group {
            if let snap = metrics?.latestSnapshot {
                Text("Last fetch: \(snap.timestamp, style: .relative) ago")
                    .font(.caption2).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12).padding(.top, 2)
            }
        }
    }

    // MARK: – Task 77: collapsible per-model cost breakdown

    private func modelBreakdownSection(metrics: AccountMetrics?) -> some View {
        let byModel = Dictionary(grouping: (metrics?.daySnapshots ?? []).flatMap { $0.modelBreakdown }, by: { $0.modelId })
        let rows: [(id: String, tok: Int, cost: Double)] = byModel.map { (id, us) in
            (id, us.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, us.reduce(0) { $0 + $1.costUSD })
        }.sorted { $0.cost > $1.cost }
        return Group {
            if !rows.isEmpty {
                DisclosureGroup(isExpanded: $showModelBreakdown) {
                    ForEach(rows, id: \.id) { row in
                        HStack {
                            Text(row.id).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            Spacer()
                            Text("\(row.tok.formatted()) tok").font(.caption2).foregroundColor(.secondary)
                            Text(String(format: "$%.4f", row.cost)).font(.caption2).monospacedDigit()
                        }.padding(.horizontal, 4)
                    }
                } label: {
                    Text("Model Breakdown").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 12))
    }

    private func confidenceRow(_ confidence: String) -> some View {
        HStack {
            Text("Cost Confidence").foregroundColor(.secondary)
            Spacer()
            Text(confidence)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(confidenceColor(confidence).opacity(0.18))
                .foregroundColor(confidenceColor(confidence))
                .clipShape(Capsule())
        }
    }

    private func confidenceColor(_ confidence: String) -> Color {
        confidence == "Billing-grade" ? .green : .orange
    }

    private func hintProviderName(hint: ModelHint, account: Account) -> String {
        let model = hint.recommendedModel.lowercased()
        if model.hasPrefix("claude") {
            return "Anthropic"
        }
        if model.hasPrefix("gpt") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            return "OpenAI"
        }
        if model.hasPrefix("gemini") {
            return "Google Gemini"
        }
        switch account.type {
        case .claudeCode, .anthropicAPI, .claudeAI:
            return "Anthropic"
        case .codex, .openAIOrg:
            return "OpenAI"
        case .gemini:
            return "Google Gemini"
        case .windsurfEnterprise:
            return "Windsurf"
        case .githubCopilot:
            return "GitHub Copilot"
        }
    }

    private func hintConfidenceLabel(_ confidence: ModelHint.SavingsConfidence) -> String {
        switch confidence {
        case .measured:
            return "Measured"
        case .profileEstimated:
            return "Profile-estimated"
        case .heuristicEstimated:
            return "Heuristic estimate"
        }
    }

    @ViewBuilder
    private func burnRateStatusRows(account: Account, metrics: AccountMetrics?) -> some View {
        if config.burnRate.enabled {
            let currentBurnRate = polling.burnRateUSDPerHourByAccount[account.id]
            let threshold = polling.burnRateThresholdUSDPerHourByAccount[account.id]
            statRow(
                "Burn Rate",
                value: burnRateValueText(currentUSDPerHour: currentBurnRate, thresholdUSDPerHour: threshold)
            )
            statRow(
                "Threshold Crossing",
                value: burnRateCrossingText(
                    currentUSDPerHour: currentBurnRate,
                    thresholdUSDPerHour: threshold,
                    forecastUSDPerHour: metrics?.latestForecast?.burnRatePerHour
                )
            )
        }
    }

    private func burnRateValueText(currentUSDPerHour: Double?, thresholdUSDPerHour: Double?) -> String {
        guard let currentUSDPerHour else { return "Insufficient data" }
        let currentText = String(format: "$%.2f/h", currentUSDPerHour)
        guard let thresholdUSDPerHour, thresholdUSDPerHour > 0 else { return "\(currentText) (limit disabled)" }
        return "\(currentText) (limit \(String(format: "$%.2f/h", thresholdUSDPerHour)))"
    }

    private func burnRateCrossingText(
        currentUSDPerHour: Double?,
        thresholdUSDPerHour: Double?,
        forecastUSDPerHour: Double?
    ) -> String {
        guard let thresholdUSDPerHour, thresholdUSDPerHour > 0 else { return "Threshold disabled" }
        guard let currentUSDPerHour else { return "Insufficient data" }
        if currentUSDPerHour >= thresholdUSDPerHour {
            return "Breaching now"
        }
        guard let forecastUSDPerHour else { return "Not projected" }
        if forecastUSDPerHour >= thresholdUSDPerHour {
            return "Projected (\(String(format: "$%.2f/h", forecastUSDPerHour)))"
        }
        return "Not projected"
    }

    private func copyActiveAccountDailyTotals() {
        guard let account = currentAccount else { return }
        let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
        let text = """
        Account: \(displayName(for: account))
        Input Tokens: \(agg.totalInputTokens)
        Output Tokens: \(agg.totalOutputTokens)
        Cost Today (USD): \(String(format: "%.4f", agg.totalCostUSD))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func displayName(for account: Account) -> String {
        let normalized = account.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return "\(account.type.rawValue)-\(account.id.uuidString.prefix(6))"
        }
        let duplicateCount = config.accounts.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }.count
        if duplicateCount > 1 {
            return "\(account.type.rawValue)-\(account.id.uuidString.prefix(6))"
        }
        return account.name
    }

    private func copyActiveAccountDebugInfo() {
        guard let account = currentAccount else { return }
        let text = """
        account_id=\(account.id.uuidString)
        provider_type=\(account.type.rawValue)
        account_name=\(account.name)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func refreshCurrentAccountMetrics() {
        guard let account = currentAccount else { return }
        viewModel.load(account: account)
    }

    private func restoreSelectedAccountIndex() {
        guard !activeAccounts.isEmpty else {
            selectedAccountIndex = 0
            return
        }
        if let savedID = UserDefaults.standard.string(forKey: selectedAccountDefaultsKey),
           let index = activeAccounts.firstIndex(where: { $0.id.uuidString == savedID }) {
            selectedAccountIndex = index
            return
        }
        if !activeAccounts.indices.contains(selectedAccountIndex) {
            selectedAccountIndex = 0
        }
    }
}
