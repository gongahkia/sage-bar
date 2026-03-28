import Charts
import SwiftUI

private actor ModelHintsMemoStore {
  private var cachedHints: [ModelHint]?
  private var cachedAt: Date?
  private let ttlSeconds: TimeInterval = 300  // 5min TTL

  func hint(for accountId: UUID) -> ModelHint? {
    if cachedHints == nil
      || (cachedAt.map { Date().timeIntervalSince($0) > ttlSeconds } ?? true)
    {
      // swiftlint:disable:previous opening_brace
      let url = AppConstants.sharedContainerURL.appendingPathComponent("model_hints.json")
      if let data = try? Data(contentsOf: url),
        let hints = try? JSONDecoder().decode([ModelHint].self, from: data)
      {
        // swiftlint:disable:previous opening_brace
        cachedHints = hints
      } else {
        cachedHints = []
      }
      cachedAt = Date()
    }
    return cachedHints?.first(where: { $0.accountId == accountId && $0.cheaperAlternativeExists })
  }

  func invalidate() {
    cachedHints = nil
    cachedAt = nil
  }
}

private struct ModelBreakdownRow {
  let id: String
  let tokens: Int
  let cost: Double
}

// swiftlint:disable:next type_body_length
struct MenuBarPopoverView: View {
  @State private var config = ConfigManager.shared.load()
  @State private var selectedAccountIndex = 0
  @State private var accountSearchText = ""
  @State private var showHistory = false
  @State private var needsReAuth: Bool = false
  @State private var showModelBreakdown = false
  @State private var copyFeedback = false
  @StateObject private var viewModel = ViewModel()
  @ObservedObject private var polling = PollingService.shared
  @ObservedObject private var errorLogger = ErrorLogger.shared
  @ObservedObject private var setupExperience = SetupExperienceStore.shared

  private struct AccountMetrics {
    let latestSnapshot: UsageSnapshot?
    let todayAggregate: DailyAggregate
    let latestForecast: ForecastSnapshot?
    let weekSnapshots: [UsageSnapshot]
    let daySnapshots: [UsageSnapshot]
    let modelHint: ModelHint?
    let lastSuccess: Date?
    let claudeAIStatus: ClaudeAIStatus?
    let claudeAIQuotaHistory: [ClaudeAIQuotaHistoryEntry]
  }

  @MainActor
  private final class ViewModel: ObservableObject {
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
        async let lastSuccess = CacheManager.shared.loadLastSuccessAsync(forAccount: account.id)
        async let claudeAIStatus = ClaudeAIStatusStore.shared.status(for: account.id)
        async let claudeAIQuotaHistory = ClaudeAIQuotaHistoryStore.shared.history(
          for: account.id, limit: 8)
        let modelHint = await Self.modelHintsMemo.hint(for: account.id)
        return await AccountMetrics(
          latestSnapshot: latestSnapshot,
          todayAggregate: todayAggregate,
          latestForecast: latestForecast,
          weekSnapshots: weekSnapshots,
          daySnapshots: daySnapshots,
          modelHint: modelHint,
          lastSuccess: lastSuccess,
          claudeAIStatus: claudeAIStatus,
          claudeAIQuotaHistory: claudeAIQuotaHistory
        )
      }.value
    }
  }

  private var activeAccounts: [Account] {
    Account.activeAccounts(in: config)
  }
  private var pinnedAccounts: [Account] {
    activeAccounts.filter(\.isPinned)
  }
  private var currentAccount: Account? {
    activeAccounts.indices.contains(selectedAccountIndex)
      ? activeAccounts[selectedAccountIndex] : activeAccounts.first
  }
  private var globalProductState: ProductStateCard? {
    ProductStateResolver.popoverGlobalState(config: config)
  }
  private var setupCTAState: ProductStateCard? {
    activeAccounts.isEmpty ? nil : ProductStateResolver.setupCTA(config: config)
  }
  private var filteredAccounts: [Account] {
    guard !accountSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return activeAccounts
    }
    let query = accountSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return activeAccounts.filter { account in
      account.resolvedDisplayName(among: activeAccounts).lowercased().contains(query)
        || (account.trimmedGroupLabel?.lowercased().contains(query) ?? false)
        || account.type.displayName.lowercased().contains(query)
    }
  }
  private var currentMetrics: AccountMetrics? {
    currentAccount.flatMap { viewModel.metrics(for: $0.id) }
  }
  private var currentAccountState: ProductStateCard? {
    guard let account = currentAccount else { return nil }
    return productState(for: account, metrics: currentMetrics)
  }
  private var shouldShowLastError: Bool {
    globalProductState == nil && currentAccount != nil && currentAccountState == nil
      && errorLogger.lastError != nil
  }

  var body: some View {
    VStack(spacing: 12) {
      header
      ScrollView {
        LazyVStack(spacing: 12) {
          if let globalProductState {
            ProductStateCardView(card: globalProductState) { action in
              handleProductStateAction(action)
            }
          } else {
            if activeAccounts.count > 1 {
              accountPickerSection
            }
            if let setupCTAState {
              ProductStateCardView(card: setupCTAState) { action in
                handleProductStateAction(action)
              }
            }
            if let account = currentAccount {
              accountSummaryCard(account: account, metrics: currentMetrics)
              if let currentAccountState {
                ProductStateCardView(card: currentAccountState) { action in
                  handleProductStateAction(action)
                }
              }
              if (needsReAuth || currentMetrics?.claudeAIStatus?.sessionHealth == .reauthRequired)
                && account.type == .claudeAI && currentAccountState == nil
              {
                // swiftlint:disable:previous opening_brace
                reAuthBanner(account: account)
              }
              if account.type == .claudeAI {
                claudeAIStatsSection(account: account, metrics: currentMetrics)
              } else {
                todayStatsSection(account: account, metrics: currentMetrics)
                modelBreakdownSection(metrics: currentMetrics)
              }
              if account.type != .claudeAI && config.forecast.showInPopover
                && config.forecast.enabled
              {
                // swiftlint:disable:previous opening_brace
                forecastSection(metrics: currentMetrics)
              }
              if account.type != .claudeAI {
                chartSection(metrics: currentMetrics)
              }
              if let hint = currentMetrics?.modelHint,
                config.modelOptimizer.enabled && config.modelOptimizer.showInPopover
              {
                // swiftlint:disable:previous opening_brace
                modelHintBanner(hint: hint, account: account)
              }
              pollHealthRow(metrics: currentMetrics)
            }
          }
          if shouldShowLastError,
            let err = errorLogger.lastError
          {
            // swiftlint:disable:previous opening_brace
            lastErrorBanner(err)
          }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
      }
      footer
    }
    .padding(.top, 12)
    .frame(width: 360)
    .background(
      LinearGradient(
        colors: [
          Color(nsColor: .windowBackgroundColor),
          // swiftlint:disable:next trailing_comma
          Color.accentColor.opacity(0.04),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
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
      AccountSelectionService.select(accountID: activeAccounts[newValue].id)
      refreshCurrentAccountMetrics()
    }
    .onChange(of: activeAccounts.map(\.id)) { _ in
      restoreSelectedAccountIndex()
      refreshCurrentAccountMetrics()
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectedAccountDidChange)) { _ in
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
    PopoverSurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Sage Bar")
              .font(.headline)
            Text("AI usage, spend, and quota from your menu bar")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          Spacer(minLength: 8)

          if polling.lastPollFailureCount > 0 {
            let partial = polling.lastPollSuccessCount > 0
            PopoverStatusPill(
              title: partial ? "Partial" : "Failed",
              color: partial ? .orange : .red
            )
          }
        }

        HStack(spacing: 8) {
          if polling.isPolling {
            ProgressView()
              .controlSize(.small)
          }

          Label("Refresh status", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption)
            .foregroundColor(.secondary)

          Spacer()

          if let date = polling.lastPollDate {
            Text(date, style: .relative)
              .font(.caption)
              .foregroundColor(.secondary)
          } else {
            Text("Not synced yet")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      }
    }
  }

  private var accountPickerSection: some View {
    PopoverSurfaceCard(title: "Accounts", systemImage: "person.2.fill") {
      VStack(alignment: .leading, spacing: 10) {
        if activeAccounts.count <= 3 {
          Picker("", selection: $selectedAccountIndex) {
            ForEach(activeAccounts.indices, id: \.self) { accountIndex in
              Text(displayName(for: activeAccounts[accountIndex])).tag(accountIndex)
            }
          }
          .pickerStyle(.segmented)
        } else {
          VStack(spacing: 8) {
            TextField("Search accounts", text: $accountSearchText)
              .textFieldStyle(.roundedBorder)
            Menu {
              if filteredAccounts.isEmpty {
                Button("No matching accounts") {}
                  .disabled(true)
              } else {
                ForEach(filteredAccounts) { account in
                  Button(displayName(for: account)) {
                    guard let index = activeAccounts.firstIndex(where: { $0.id == account.id })
                    else { return }
                    selectedAccountIndex = index
                  }
                }
              }
            } label: {
              HStack {
                Text(currentAccount.map(displayName(for:)) ?? "Select account")
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }
        }

        if !pinnedAccounts.isEmpty {
          pinnedAccountsRow
        }
      }
    }
  }

  private var pinnedAccountsRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(pinnedAccounts) { account in
          Button(displayName(for: account)) {
            AccountSelectionService.select(accountID: account.id)
          }
          .buttonStyle(.bordered)
          .font(.caption2)
        }
      }
    }
  }

  private func accountSummaryCard(account: Account, metrics: AccountMetrics?) -> some View {
    PopoverAccountSummaryCard(
      title: displayName(for: account),
      subtitle: account.trimmedGroupLabel ?? account.type.displayName,
      accessoryTitle: accountSummaryAccessoryTitle(for: account),
      accessoryValue: accountSummaryAccessoryValue(for: account, metrics: metrics),
      confidence: currentCostConfidence(account: account, latestSnapshot: metrics?.latestSnapshot),
      lastFetch: metrics?.lastSuccess ?? metrics?.latestSnapshot?.timestamp
    )
  }

  // MARK: – Today stats
  private func todayStatsSection(account: Account, metrics: AccountMetrics?) -> some View {
    let agg =
      metrics?.todayAggregate
      ?? DailyAggregate(
        date: Calendar.current.dateComponents([.year, .month, .day], from: Date()),
        snapshots: []
      )
    let confidence = currentCostConfidence(
      account: account, latestSnapshot: metrics?.latestSnapshot)
    let inputLabel = account.type == .githubCopilot ? "Suggestions / Chats" : "Input Tokens"
    let outputLabel = account.type == .githubCopilot ? "Acceptances / Actions" : "Output Tokens"
    return PopoverSurfaceCard(title: "Today", systemImage: "calendar") {
      VStack(alignment: .leading, spacing: 6) {
        statRow(inputLabel, value: "\(agg.totalInputTokens.formatted())")
        statRow(outputLabel, value: "\(agg.totalOutputTokens.formatted())")
        statRow(
          "Cache Tokens",
          value:
            "\((agg.snapshots.reduce(0) { $0 + $1.cacheReadTokens + $1.cacheCreationTokens }).formatted())"
        )
        statRow("Cost Today", value: String(format: "$%.4f", agg.totalCostUSD))
        burnRateStatusRows(account: account, metrics: metrics)
        confidenceRow(confidence)
      }
    }
  }

  // MARK: – Forecast
  private func forecastSection(metrics: AccountMetrics?) -> some View {
    PopoverSurfaceCard(title: "Forecast", systemImage: "chart.line.uptrend.xyaxis") {
      if let forecast = metrics?.latestForecast {
        VStack(alignment: .leading, spacing: 6) {
          statRow("EOD", value: String(format: "$%.2f", forecast.projectedEODCostUSD))
          statRow("EOW", value: String(format: "$%.2f", forecast.projectedEOWCostUSD))
          statRow("EOM", value: String(format: "$%.2f", forecast.projectedEOMCostUSD))
        }
      } else {
        Text("Not enough data yet")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }

  // MARK: – 7-day chart
  private func chartSection(metrics: AccountMetrics?) -> some View {
    let snaps = metrics?.weekSnapshots ?? []
    let cal = Calendar.current
    let byDay: [(Date, Double)] = Dictionary(
      grouping: snaps,
      by: {
        cal.startOfDay(for: $0.timestamp)
      }
    ).map { ($0.key, $0.value.reduce(0) { $0 + $1.totalCostUSD }) }
      .sorted { $0.0 < $1.0 }
    return PopoverSurfaceCard(title: "7-Day Spend", systemImage: "chart.bar.xaxis") {
      if !byDay.isEmpty {
        Chart(byDay, id: \.0) { dayCost in
          BarMark(
            x: .value("Day", dayCost.0, unit: .day),
            y: .value("Cost", dayCost.1)
          )
          .foregroundStyle(Color.accentColor.gradient)
        }
        .chartXAxis {
          AxisMarks(values: .stride(by: .day)) { _ in
            AxisTick()
            AxisGridLine()
          }
        }
        .frame(height: 96)
      } else {
        Text("Not enough data yet")
          .font(.caption)
          .foregroundColor(.secondary)
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
        PopoverSurfaceCard(
          title: "\(provider) Hint", systemImage: "lightbulb.fill", accentColor: .yellow
        ) {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Switch to \(hint.recommendedModel)")
                .font(.caption.weight(.semibold))
              Spacer()
              Button {
                UserDefaults.standard.set(Date(), forKey: dismissKey)
              } label: {
                Image(systemName: "xmark").font(.caption2)
              }
              .buttonStyle(.plain)
              .foregroundColor(.secondary)
            }
            Text("↓ ~\(String(format: "$%.2f", hint.estimatedSavingsUSD))/day")
              .font(.caption)
            Text("Confidence: \(confidence)")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }
      }
    }
  }

  // MARK: – Poll health
  private func pollHealthRow(metrics: AccountMetrics?) -> some View {
    let staleMultiplier = 2.0
    return PopoverSurfaceCard(title: "Polling Health", systemImage: "waveform.path.ecg") {
      VStack(alignment: .leading, spacing: 6) {
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
        if let last = metrics?.lastSuccess ?? polling.lastPollDate {
          statRow("Last synced", value: last.formatted(.relative(presentation: .named)))
          let next = last.addingTimeInterval(TimeInterval(config.pollIntervalSeconds))
          statRow("Next poll", value: next.formatted(.relative(presentation: .named)))
        } else {
          statRow("Last synced", value: "Never")
        }
      }
    }
  }

  // MARK: – ClaudeAI stats
  private func claudeAIStatsSection(account: Account, metrics: AccountMetrics?) -> some View {
    return PopoverSurfaceCard(title: "Claude.ai Quota", systemImage: "message.badge.fill") {
      VStack(alignment: .leading, spacing: 6) {
        if let status = metrics?.claudeAIStatus {
          statRow("Messages remaining", value: "\(status.messagesRemaining)")
          statRow("Messages used", value: "\(status.messagesUsed)")
          statRow(
            "Reset time",
            value: status.resetAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
          statRow("Reset in", value: resetCountdownText(for: status))
          statRow("Session", value: claudeAISessionText(for: status))
          if config.claudeAI.notifyOnLowMessages
            && status.messagesRemaining <= config.claudeAI.lowMessagesThreshold
          {
            // swiftlint:disable:previous opening_brace
            statRow("Low quota", value: "At or below \(config.claudeAI.lowMessagesThreshold)")
          }
          if let lastSuccessfulSyncAt = status.lastSuccessfulSyncAt {
            statRow(
              "Last healthy sync",
              value: lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened))
          }
          if let lastErrorMessage = status.lastErrorMessage, status.sessionHealth != .healthy {
            Text(lastErrorMessage)
              .font(.caption2)
              .foregroundColor(status.sessionHealth == .reauthRequired ? .orange : .secondary)
          }
          quotaHistorySection(metrics?.claudeAIQuotaHistory ?? [])
        } else {
          Text("No data yet")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        confidenceRow(
          currentCostConfidence(account: account, latestSnapshot: metrics?.latestSnapshot))
      }
    }
  }

  private func currentCostConfidence(account: Account, latestSnapshot: UsageSnapshot?) -> String {
    if let latest = latestSnapshot {
      return latest.costConfidence == .billingGrade ? "Billing-grade" : "Estimated"
    }
    return (account.type == .anthropicAPI || account.type == .openAIOrg)
      ? "Billing-grade" : "Estimated"
  }

  // MARK: – Re-auth banner
  @State private var inlineSessionToken = ""
  @State private var inlineTokenSaving = false
  @State private var inlineTokenSaved = false
  private func reAuthBanner(account: Account) -> some View {
    PopoverSurfaceCard(accentColor: .orange) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "key.fill").foregroundColor(.orange)
          Text("claude.ai session needs attention.")
            .font(.caption)
            .lineLimit(1)
          Spacer()
          Button("Settings") {
            SettingsWindowController.shared.showWindow()
          }
          .buttonStyle(.borderless)
          .font(.caption2)
          Button {
            needsReAuth = false
          } label: {
            Image(systemName: "xmark").font(.caption2)
          }
          .buttonStyle(.plain)
        }
        HStack(spacing: 6) {
          SecureField("Paste session token", text: $inlineSessionToken)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
          Button(inlineTokenSaved ? "Saved" : "Save") {
            guard !inlineSessionToken.isEmpty else { return }
            inlineTokenSaving = true
            do {
              try KeychainManager.store(
                key: inlineSessionToken,
                service: AppConstants.keychainSessionTokenService,
                account: account.id.uuidString
              )
              inlineTokenSaved = true
              inlineSessionToken = ""
              needsReAuth = false
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { inlineTokenSaved = false }
            } catch {
              ErrorLogger.shared.log("Failed to save session token: \(error.localizedDescription)", level: "ERROR")
            }
            inlineTokenSaving = false
          }
          .buttonStyle(.borderless)
          .font(.caption2)
          .disabled(inlineSessionToken.isEmpty || inlineTokenSaving)
        }
      }
    }
  }

  // MARK: – Last Error
  private func lastErrorBanner(_ err: AppError) -> some View {
    PopoverSurfaceCard(accentColor: .red) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.red)
          .font(.caption)
        VStack(alignment: .leading, spacing: 2) {
          Text(err.message)
            .font(.caption)
            .lineLimit(2)
          Text(err.timestamp, style: .relative)
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        Spacer()
        Button {
          errorLogger.lastError = nil
        } label: {
          Image(systemName: "xmark").font(.caption2)
        }
        .buttonStyle(.plain)
      }
    }
  }

  // MARK: – Footer
  private var footer: some View {
    HStack {
      if activeAccounts.count > 1 {
        ControlGroup {
          Button("Prev") { selectPreviousAccount() }
            .keyboardShortcut("[", modifiers: .command)
          Button("Next") { selectNextAccount() }
            .keyboardShortcut("]", modifiers: .command)
        }
        .controlSize(.small)
      }
      Button("Refresh") { PollingService.shared.forceRefresh() }
        .keyboardShortcut("r", modifiers: .command)
        .controlSize(.small)
      Button(copyFeedback ? "Copied" : "Copy Totals") {
        copyActiveAccountDailyTotals()
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copyFeedback = false }
      }
      .controlSize(.small)
      Spacer()
      if config.analytics.enabled {
        Button("History") { showHistory = true }
          .controlSize(.small)
      }
      Menu("More") {
        Button("Export CSV") {
          exportAllActiveAccountsCSV()
        }
        Button("Copy Account Info") {
          copyActiveAccountDebugInfo()
        }
      }
      .controlSize(.small)
      Button("Settings…") {
        SettingsWindowController.shared.showWindow()
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
  }

  private func accountSummaryAccessoryTitle(for account: Account) -> String {
    account.type == .claudeAI ? "Remaining" : "Today"
  }

  private func accountSummaryAccessoryValue(for account: Account, metrics: AccountMetrics?)
    -> String
  {
    // swiftlint:disable:previous opening_brace
    if account.type == .claudeAI {
      return metrics?.claudeAIStatus.map { "\($0.messagesRemaining) messages" } ?? "No quota yet"
    }
    let aggregate =
      metrics?.todayAggregate
      ?? DailyAggregate(
        date: Calendar.current.dateComponents([.year, .month, .day], from: Date()),
        snapshots: []
      )
    return String(format: "$%.4f", aggregate.totalCostUSD)
  }

  // MARK: – Task 77: collapsible per-model cost breakdown

  private func modelBreakdownSection(metrics: AccountMetrics?) -> some View {
    let byModel = Dictionary(
      grouping: (metrics?.daySnapshots ?? []).flatMap { $0.modelBreakdown }, by: { $0.modelId })
    let rows: [ModelBreakdownRow] = byModel.map { modelId, usages in
      ModelBreakdownRow(
        id: modelId,
        tokens: usages.reduce(0) { $0 + $1.inputTokens + $1.outputTokens },
        cost: usages.reduce(0) { $0 + $1.costUSD }
      )
    }.sorted { $0.cost > $1.cost }
    return Group {
      if !rows.isEmpty {
        PopoverSurfaceCard(title: "Model Breakdown", systemImage: "square.stack.3d.down.right") {
          DisclosureGroup(isExpanded: $showModelBreakdown) {
            ForEach(rows, id: \.id) { row in
              HStack {
                Text(row.id).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Text("\(row.tokens.formatted()) tok").font(.caption2).foregroundColor(.secondary)
                Text(String(format: "$%.4f", row.cost)).font(.caption2).monospacedDigit()
              }
              .padding(.horizontal, 4)
            }
          } label: {
            Text(showModelBreakdown ? "Hide per-model totals" : "Show per-model totals")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
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
    if model.hasPrefix("gpt") || model.hasPrefix("o1") || model.hasPrefix("o3")
      || model.hasPrefix("o4")
    {
      // swiftlint:disable:previous opening_brace
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

  private func burnRateValueText(currentUSDPerHour: Double?, thresholdUSDPerHour: Double?) -> String
  {
    // swiftlint:disable:previous opening_brace
    guard let currentUSDPerHour else { return "Insufficient data" }
    let currentText = String(format: "$%.2f/h", currentUSDPerHour)
    guard let thresholdUSDPerHour, thresholdUSDPerHour > 0 else {
      return "\(currentText) (limit disabled)"
    }
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
    _ = UsageReportingService.copySummaryToPasteboard(for: account, among: activeAccounts)
  }

  private func displayName(for account: Account) -> String {
    account.displayLabel(among: activeAccounts)
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
    if let status = viewModel.metrics(for: account.id)?.claudeAIStatus {
      needsReAuth = status.sessionHealth == .reauthRequired
    }
  }

  private func exportAllActiveAccountsCSV() {
    do {
      _ = try UsageReportingService.exportCSV(for: activeAccounts)
    } catch {
      ErrorLogger.shared.log("Export active accounts CSV failed: \(error.localizedDescription)")
    }
  }

  private func restoreSelectedAccountIndex() {
    guard !activeAccounts.isEmpty else {
      selectedAccountIndex = 0
      return
    }
    if let current = AccountSelectionService.currentAccount(in: activeAccounts),
      let index = activeAccounts.firstIndex(where: { $0.id == current.id })
    {
      // swiftlint:disable:previous opening_brace
      selectedAccountIndex = index
      return
    }
    if !activeAccounts.indices.contains(selectedAccountIndex) {
      selectedAccountIndex = 0
    }
  }

  private func selectPreviousAccount() {
    guard let selected = AccountSelectionService.selectPrevious(in: activeAccounts),
      let index = activeAccounts.firstIndex(where: { $0.id == selected.id })
    else { return }
    selectedAccountIndex = index
  }

  private func selectNextAccount() {
    guard let selected = AccountSelectionService.selectNext(in: activeAccounts),
      let index = activeAccounts.firstIndex(where: { $0.id == selected.id })
    else { return }
    selectedAccountIndex = index
  }

  private func resetCountdownText(for status: ClaudeAIStatus) -> String {
    guard let resetAt = status.resetAt else { return "Unknown" }
    let remaining = max(0, Int(resetAt.timeIntervalSinceNow))
    let hours = remaining / 3600
    let minutes = (remaining % 3600) / 60
    return "\(hours)h \(minutes)m"
  }

  private func claudeAISessionText(for status: ClaudeAIStatus) -> String {
    switch status.sessionHealth {
    case .healthy:
      return "Healthy"
    case .temporaryFailure:
      return "Using last known quota"
    case .reauthRequired:
      return "Re-auth required"
    }
  }

  @ViewBuilder
  private func quotaHistorySection(_ history: [ClaudeAIQuotaHistoryEntry]) -> some View {
    if !history.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("Quota History").font(.caption).foregroundColor(.secondary)
        ForEach(history.prefix(4)) { entry in
          HStack {
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
              .font(.caption2)
              .foregroundColor(.secondary)
            Spacer()
            Text("\(entry.messagesRemaining) left")
              .font(.caption2)
              .monospacedDigit()
          }
        }
      }
      .padding(.top, 4)
    }
  }

  private func productState(for account: Account, metrics: AccountMetrics?) -> ProductStateCard? {
    ProductStateResolver.accountState(
      for: account,
      latestSnapshot: metrics?.latestSnapshot,
      lastSuccess: metrics?.lastSuccess,
      claudeAIStatus: metrics?.claudeAIStatus,
      fetchErrorMessage: polling.fetchErrorMessage(for: account.id),
      fetchErrorUpdatedAt: polling.fetchErrorUpdatedAt(for: account.id),
      pollIntervalSeconds: config.pollIntervalSeconds
    )
  }

  private func handleProductStateAction(_ action: ProductStateActionKind) {
    switch action {
    case .runSetupWizard:
      OnboardingWindowController.shared.showWindow(force: true)
    case .openAccountsSettings, .reconnectSettings, .openSettings:
      SettingsWindowController.shared.showWindow()
    case .refreshNow:
      PollingService.shared.forceRefresh()
    case .disableDemoMode:
      SetupExperienceStore.shared.disableDemoMode()
      config = ConfigManager.shared.load()
    case .resetDateRange, .exportAllTime:
      break
    }
  }
}

private struct PopoverSurfaceCard<Content: View>: View {
  var title: String?
  var systemImage: String?
  var accentColor: Color
  @ViewBuilder var content: () -> Content

  init(
    title: String? = nil,
    systemImage: String? = nil,
    accentColor: Color = .accentColor,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.accentColor = accentColor
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let title {
        Label(title, systemImage: systemImage ?? "circle.fill")
          .font(.caption.weight(.semibold))
          .foregroundColor(.secondary)
      }

      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(accentColor.opacity(0.14), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.05), radius: 14, y: 6)
  }
}

private struct PopoverStatusPill: View {
  let title: String
  let color: Color

  var body: some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.16))
      .foregroundColor(color)
      .clipShape(Capsule())
  }
}

private struct PopoverAccountSummaryCard: View {
  let title: String
  let subtitle: String
  let accessoryTitle: String
  let accessoryValue: String
  let confidence: String
  let lastFetch: Date?

  var body: some View {
    PopoverSurfaceCard(accentColor: confidence == "Billing-grade" ? .green : .orange) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(title)
              .font(.headline)
            Text(subtitle)
              .font(.caption)
              .foregroundColor(.secondary)
          }

          Spacer(minLength: 12)

          PopoverStatusPill(
            title: confidence,
            color: confidence == "Billing-grade" ? .green : .orange
          )
        }

        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(accessoryTitle)
              .font(.caption2)
              .foregroundColor(.secondary)
            Text(accessoryValue)
              .font(.system(size: 20, weight: .semibold, design: .rounded))
          }

          Spacer()

          VStack(alignment: .trailing, spacing: 2) {
            Text("Last fetch")
              .font(.caption2)
              .foregroundColor(.secondary)
            if let lastFetch {
              Text(lastFetch, style: .relative)
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
              Text("Never")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }
      }
    }
  }
}
