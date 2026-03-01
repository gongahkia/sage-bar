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
    @ObservedObject private var polling = PollingService.shared
    @ObservedObject private var errorLogger = ErrorLogger.shared

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
                accountFetchLabel(account: account) // task 78: per-account relative last-fetch
                if needsReAuth && account.type == .claudeAI {
                    reAuthBanner
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if account.type == .claudeAI {
                            claudeAIStatsSection(account: account)
                        } else {
                            todayStatsSection(account: account)
                            modelBreakdownSection(account: account) // task 77
                        }
                        if account.type != .claudeAI && config.forecast.showInPopover && config.forecast.enabled {
                            forecastSection(account: account)
                        }
                        if account.type != .claudeAI {
                            chartSection(account: account)
                        }
                        if let hint = modelHint(account: account),
                           config.modelOptimizer.enabled && config.modelOptimizer.showInPopover {
                            modelHintBanner(hint: hint, account: account)
                        }
                        pollHealthRow
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
        }
        .onChange(of: selectedAccountIndex) { _, newValue in
            guard activeAccounts.indices.contains(newValue) else { return }
            UserDefaults.standard.set(activeAccounts[newValue].id.uuidString, forKey: selectedAccountDefaultsKey)
        }
        .onChange(of: activeAccounts.map(\.id)) { _, _ in
            restoreSelectedAccountIndex()
        }
    }

    // MARK: – Header
    private var header: some View {
        HStack {
            Text("Claude Usage").font(.headline)
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
    private func todayStatsSection(account: Account) -> some View {
        let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
        let confidence = currentCostConfidence(account: account)
        return VStack(alignment: .leading, spacing: 4) {
            statRow("Input Tokens", value: "\(agg.totalInputTokens.formatted())")
            statRow("Output Tokens", value: "\(agg.totalOutputTokens.formatted())")
            statRow("Cache Tokens", value: "\((CacheManager.shared.todayAggregate(forAccount: account.id).snapshots.reduce(0) { $0 + $1.cacheReadTokens + $1.cacheCreationTokens }).formatted())")
            statRow("Cost Today", value: String(format: "$%.4f", agg.totalCostUSD))
            confidenceRow(confidence)
        }.padding(12)
    }

    // MARK: – Forecast
    private func forecastSection(account: Account) -> some View {
        Group {
            if let f = CacheManager.shared.latestForecast(forAccount: account.id) {
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
    private func chartSection(account: Account) -> some View {
        let snaps = CacheManager.shared.history(forAccount: account.id, days: 7)
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
    private func modelHint(account: Account) -> ModelHint? {
        guard let data = try? Data(contentsOf: AppConstants.sharedContainerURL.appendingPathComponent("model_hints.json")),
              let hints = try? JSONDecoder().decode([ModelHint].self, from: data) else { return nil }
        return hints.first(where: { $0.accountId == account.id && $0.cheaperAlternativeExists })
    }

    private func modelHintBanner(hint: ModelHint, account: Account) -> some View {
        let dismissKey = "modelHintDismissed_\(account.id.uuidString)"
        let dismissed = UserDefaults.standard.object(forKey: dismissKey) as? Date
        let shouldShow = dismissed.map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true
        return Group {
            if shouldShow {
                HStack {
                    Image(systemName: "lightbulb").foregroundColor(.yellow)
                    Text("↓ ~\(String(format: "$%.2f", hint.estimatedSavingsUSD))/day switching to \(hint.recommendedModel)")
                        .font(.caption)
                    Spacer()
                    Button(action: { UserDefaults.standard.set(Date(), forKey: dismissKey) }) {
                        Image(systemName: "xmark").font(.caption2)
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.yellow.opacity(0.1)).cornerRadius(6).padding(.horizontal, 12)
            }
        }
    }

    // MARK: – Poll health
    private var pollHealthRow: some View {
        let staleMultiplier = 2.0
        return VStack(alignment: .leading, spacing: 2) {
            if let account = currentAccount,
               let latest = CacheManager.shared.latest(forAccount: account.id) {
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
    private func claudeAIStatsSection(account: Account) -> some View {
        let snap = CacheManager.shared.latest(forAccount: account.id)
        let remaining = snap?.modelBreakdown.first(where: { $0.modelId == "claude-ai-web" })?.inputTokens
        return VStack(alignment: .leading, spacing: 4) {
            if let r = remaining {
                statRow("Messages remaining", value: "\(r)")
            } else {
                Text("No data yet").font(.caption).foregroundColor(.secondary)
            }
            confidenceRow(currentCostConfidence(account: account))
        }.padding(12)
    }

    private func currentCostConfidence(account: Account) -> String {
        if let latest = CacheManager.shared.latest(forAccount: account.id) {
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

    private func accountFetchLabel(account: Account) -> some View {
        Group {
            if let snap = CacheManager.shared.latest(forAccount: account.id) {
                Text("Last fetch: \(snap.timestamp, style: .relative) ago")
                    .font(.caption2).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12).padding(.top, 2)
            }
        }
    }

    // MARK: – Task 77: collapsible per-model cost breakdown

    private func modelBreakdownSection(account: Account) -> some View {
        let snaps = CacheManager.shared.history(forAccount: account.id, days: 1)
        let byModel = Dictionary(grouping: snaps.flatMap { $0.modelBreakdown }, by: { $0.modelId })
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
