import SwiftUI
import Charts

struct DashboardView: View {
    @State private var config = ConfigManager.shared.load()
    @State private var selectedAccountId: UUID?
    @State private var weekSnapshots: [UUID: [UsageSnapshot]] = [:]
    @State private var todayAggregates: [UUID: DailyAggregate] = [:]
    @State private var liveEntries: [LiveLogEntry] = []
    @State private var dashTab: DashTab = .overview

    private var accounts: [Account] { Account.activeAccounts(in: config) }
    private var selectedAccount: Account? {
        accounts.first { $0.id == selectedAccountId } ?? accounts.first
    }

    enum DashTab: String, CaseIterable {
        case overview = "Overview"
        case live = "Live"
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .frame(minWidth: 640, minHeight: 420)
        .task { await loadAll() }
        .onReceive(NotificationCenter.default.publisher(for: .usageDidUpdate)) { _ in
            Task { await loadAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeCodeLogsChanged)) { _ in
            appendLiveEntry(provider: "Claude Code")
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexLogsChanged)) { _ in
            appendLiveEntry(provider: "Codex")
        }
        .onReceive(NotificationCenter.default.publisher(for: .geminiLogsChanged)) { _ in
            appendLiveEntry(provider: "Gemini")
        }
    }

    // MARK: - sidebar
    private var sidebar: some View {
        List(selection: $selectedAccountId) {
            Section("Accounts") {
                ForEach(accounts, id: \.id) { account in
                    accountRow(account)
                        .tag(account.id)
                }
            }
            Section {
                Picker("View", selection: $dashTab) {
                    ForEach(DashTab.allCases, id: \.self) { t in
                        Label(t.rawValue, systemImage: t == .overview ? "chart.bar.xaxis" : "bolt.fill")
                            .tag(t)
                    }
                }.pickerStyle(.inline).labelsHidden()
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    private func accountRow(_ account: Account) -> some View {
        let agg = todayAggregates[account.id]
        let cost = agg?.totalCostUSD ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(providerColor(account.type))
                    .frame(width: 8, height: 8)
                Text(account.name.isEmpty ? account.type.displayName : account.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            HStack {
                Text(String(format: "$%.4f", cost))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(account.type.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - detail
    @ViewBuilder
    private var detailView: some View {
        switch dashTab {
        case .overview: overviewTab
        case .live: liveTab
        }
    }

    // MARK: - overview tab
    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCostCard
                if let account = selectedAccount, let snaps = weekSnapshots[account.id], snaps.count >= 2 {
                    weeklyChartCard(snaps: snaps)
                }
                if let account = selectedAccount {
                    tokenBreakdownCard(account: account)
                }
                if let account = selectedAccount, config.forecast.enabled {
                    forecastCard(account: account)
                }
            }
            .padding(20)
        }
    }

    private var heroCostCard: some View {
        let totalCost = todayAggregates.values.reduce(0) { $0 + $1.totalCostUSD }
        let totalTokens = todayAggregates.values.reduce(0) { $0 + $1.totalInputTokens + $1.totalOutputTokens }
        return DashCard {
            VStack(spacing: 8) {
                Text("Today — All Accounts")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "$%.4f", totalCost))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: totalCost)
                HStack(spacing: 16) {
                    Label("\(totalTokens.formatted()) tokens", systemImage: "arrow.left.arrow.right")
                    Label("\(accounts.count) accounts", systemImage: "person.2")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private func weeklyChartCard(snaps: [UsageSnapshot]) -> some View {
        let byDay = groupedByDay(snaps)
        return DashCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("7-Day Spend")
                    .font(.headline)
                Chart(byDay, id: \.0) { item in
                    BarMark(
                        x: .value("Day", item.0, unit: .day),
                        y: .value("Cost", item.1)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [providerColor(selectedAccount?.type ?? .claudeCode), providerColor(selectedAccount?.type ?? .claudeCode).opacity(0.4)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .cornerRadius(4)
                }
                .chartYAxis { AxisMarks(format: .currency(code: "USD")) }
                .frame(height: 180)
            }
        }
    }

    private func tokenBreakdownCard(account: Account) -> some View {
        let agg = todayAggregates[account.id] ?? DailyAggregate(
            date: Calendar.current.dateComponents([.year, .month, .day], from: Date()),
            snapshots: []
        )
        let latest = agg.snapshots.last
        return DashCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Token Breakdown")
                    .font(.headline)
                HStack(spacing: 20) {
                    tokenStat("Input", value: agg.totalInputTokens, color: providerColor(account.type))
                    tokenStat("Output", value: agg.totalOutputTokens, color: providerColor(account.type).opacity(0.7))
                    let cache = agg.snapshots.reduce(0) { $0 + $1.cacheCreationTokens + $1.cacheReadTokens }
                    tokenStat("Cache", value: cache, color: providerColor(account.type).opacity(0.4))
                }
                if let models = latest?.modelBreakdown, !models.isEmpty {
                    Divider()
                    ForEach(models, id: \.modelId) { m in
                        HStack {
                            Text(m.modelId).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("\((m.inputTokens + m.outputTokens).formatted()) tok")
                                .font(.system(size: 11, design: .monospaced))
                            Text(String(format: "$%.4f", m.costUSD))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func forecastCard(account: Account) -> some View {
        let forecast = CacheManager.shared.latestForecast(forAccount: account.id)
        let snaps = weekSnapshots[account.id] ?? []
        let byDay = groupedByDay(snaps)
        return DashCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Forecast").font(.headline)
                if let f = forecast, !byDay.isEmpty {
                    forecastChart(historical: byDay, forecast: f)
                    HStack(spacing: 20) {
                        forecastStat("EOD", value: f.projectedEODCostUSD)
                        forecastStat("EOW", value: f.projectedEOWCostUSD)
                        forecastStat("EOM", value: f.projectedEOMCostUSD)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "flame")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text(String(format: "Burn rate: $%.4f/hr", f.burnRatePerHour))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("Not enough data for forecast")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func forecastChart(historical: [(Date, Double)], forecast: ForecastSnapshot) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let eow = cal.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? cal.date(byAdding: .day, value: 7, to: today)!
        let projected: [(Date, Double)] = [
            (today, historical.last?.1 ?? 0),
            (cal.date(byAdding: .day, value: 1, to: today)!, forecast.projectedEODCostUSD),
            (eow, forecast.projectedEOWCostUSD),
        ]
        return Chart {
            ForEach(historical, id: \.0) { item in
                LineMark(x: .value("Day", item.0), y: .value("Cost", item.1))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                AreaMark(x: .value("Day", item.0), y: .value("Cost", item.1))
                    .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
            }
            ForEach(projected, id: \.0) { item in
                LineMark(x: .value("Day", item.0), y: .value("Cost", item.1))
                    .foregroundStyle(Color.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .chartYAxis { AxisMarks(format: .currency(code: "USD")) }
        .frame(height: 140)
    }

    // MARK: - live tab
    private var liveTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live Activity")
                    .font(.headline)
                Spacer()
                Text("\(liveEntries.count) events")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Clear") { liveEntries.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(12)
            Divider()
            if liveEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No activity yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Events appear here as local providers log usage")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(liveEntries.reversed()) { entry in
                            liveEntryRow(entry)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func liveEntryRow(_ entry: LiveLogEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.provider == "Claude Code" ? Color.orange :
                      entry.provider == "Codex" ? Color.teal : Color.blue)
                .frame(width: 6, height: 6)
            Text(entry.provider)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 80, alignment: .leading)
            Text(entry.timestamp, style: .time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - helpers
    private func tokenStat(_ label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func forecastStat(_ label: String, value: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "$%.2f", value))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func groupedByDay(_ snaps: [UsageSnapshot]) -> [(Date, Double)] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let recent = snaps.filter { $0.timestamp >= cutoff }
        return Dictionary(grouping: recent) { cal.startOfDay(for: $0.timestamp) }
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.totalCostUSD }) }
            .sorted { $0.0 < $1.0 }
    }

    private func providerColor(_ type: AccountType) -> Color {
        switch type {
        case .anthropicAPI, .claudeCode: return Color(red: 0.9, green: 0.42, blue: 0.31) // coral
        case .openAIOrg, .codex: return Color(red: 0.06, green: 0.64, blue: 0.5) // teal
        case .githubCopilot: return Color(red: 0.54, green: 0.34, blue: 0.9) // purple
        case .windsurfEnterprise: return Color(red: 0.15, green: 0.39, blue: 0.92) // blue
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96) // google blue
        case .claudeAI: return Color(red: 0.85, green: 0.55, blue: 0.3) // amber
        }
    }

    private func appendLiveEntry(provider: String) {
        let entry = LiveLogEntry(provider: provider, timestamp: Date())
        liveEntries.append(entry)
        if liveEntries.count > 200 { liveEntries.removeFirst(liveEntries.count - 200) }
    }

    private func loadAll() async {
        config = ConfigManager.shared.load()
        if selectedAccountId == nil { selectedAccountId = accounts.first?.id }
        for account in accounts {
            weekSnapshots[account.id] = await CacheManager.shared.historyAsync(forAccount: account.id, days: 7)
            todayAggregates[account.id] = await CacheManager.shared.todayAggregateAsync(forAccount: account.id)
        }
    }
}

struct LiveLogEntry: Identifiable {
    let id = UUID()
    let provider: String
    let timestamp: Date
}

struct DashCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }
}
