import SwiftUI
import Charts

struct MenuBarPopoverView: View {
    @State private var config = ConfigManager.shared.load()
    @State private var selectedAccountIndex = 0
    @State private var showHistory = false
    @State private var needsReAuth: Bool = false
    @State private var showModelBreakdown = false
    @ObservedObject private var polling = PollingService.shared
    @ObservedObject private var errorLogger = ErrorLogger.shared

    private var activeAccounts: [Account] { config.accounts.filter { $0.isActive } }
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
    }

    // MARK: – Header
    private var header: some View {
        HStack {
            Text("Claude Usage").font(.headline)
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
                Text(activeAccounts[i].name).tag(i)
            }
        }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: – Today stats
    private func todayStatsSection(account: Account) -> some View {
        let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
        return VStack(alignment: .leading, spacing: 4) {
            statRow("Input Tokens", value: "\(agg.totalInputTokens.formatted())")
            statRow("Output Tokens", value: "\(agg.totalOutputTokens.formatted())")
            statRow("Cache Tokens", value: "\((CacheManager.shared.todayAggregate(forAccount: account.id).snapshots.reduce(0) { $0 + $1.cacheReadTokens + $1.cacheCreationTokens }).formatted())")
            statRow("Cost Today", value: String(format: "$%.4f", agg.totalCostUSD))
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
        let stale = currentAccount.flatMap { CacheManager.shared.latest(forAccount: $0.id) }?.isStale ?? false
        return VStack(alignment: .leading, spacing: 2) {
            if let last = polling.lastPollDate {
                statRow("Last synced", value: last.formatted(.relative(presentation: .named)) + (stale ? " (stale)" : ""))
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
        }.padding(12)
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
}
