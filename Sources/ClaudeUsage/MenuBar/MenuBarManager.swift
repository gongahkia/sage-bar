import AppKit
import SwiftUI
import Combine
import Sparkle

@MainActor
class MenuBarManager {
    static let shared = MenuBarManager()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let contextMenu = NSMenu()
    private let mainMenu = NSMenu()
    private var monitor: Any?
    private var throttleWorkItem: DispatchWorkItem?
    private var secondStatusItem: NSStatusItem? // dual icon support
    private(set) var updaterController: SPUStandardUpdaterController?

    private init() {}

    func setup(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = MenuBarIconRenderer.renderFromSnapshot(nil, health: .healthy)
            btn.action = #selector(handleStatusItemClick(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        contextMenu.removeAllItems()
        for item in buildContextMenu().items {
            contextMenu.addItem(item)
        }
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 560)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView())

        NotificationCenter.default.addObserver(
            forName: .usageDidUpdate, object: nil, queue: .main
        ) { [weak self] notif in
            Task { [weak self] in
                await self?.onUsageUpdate(notif)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .claudeCodeLogsChanged, object: nil, queue: .main
        ) { _ in
            Task { await PollingService.shared.handleClaudeCodeLogsChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: .codexLogsChanged, object: nil, queue: .main
        ) { _ in
            Task { await PollingService.shared.handleClaudeCodeLogsChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: .geminiLogsChanged, object: nil, queue: .main
        ) { _ in
            Task { await PollingService.shared.handleClaudeCodeLogsChanged() }
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let setupItem = NSMenuItem(title: "Run Setup Wizard", action: #selector(runSetupWizard), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)
        let nextAccountItem = NSMenuItem(title: "Next Account", action: #selector(selectNextAccountFromMenu), keyEquivalent: "]")
        nextAccountItem.target = self
        menu.addItem(nextAccountItem)
        let previousAccountItem = NSMenuItem(title: "Previous Account", action: #selector(selectPreviousAccountFromMenu), keyEquivalent: "[")
        previousAccountItem.target = self
        menu.addItem(previousAccountItem)
        let exportUsageItem = NSMenuItem(title: "Export All Active Accounts CSV…", action: #selector(exportAllActiveAccountsCSV), keyEquivalent: "")
        exportUsageItem.target = self
        menu.addItem(exportUsageItem)
        let diagItem = NSMenuItem(title: "Export Diagnostics…", action: #selector(exportDiagnostics), keyEquivalent: "")
        diagItem.target = self
        menu.addItem(diagItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc private func exportDiagnostics() {
        let recentLogs = ErrorLogger.shared.readLast(300)
        let highSignalLogs = recentLogs.filter { line in
            line.contains("[WARN]") || line.contains("[ERROR]")
        }
        let selectedLogs = highSignalLogs.isEmpty ? Array(recentLogs.suffix(100)) : Array(highSignalLogs.suffix(100))
        let errors = selectedLogs.joined(separator: "\n")
        var config = ConfigManager.shared.load()
        // sanitize sensitive fields
        if !config.webhook.url.isEmpty { config.webhook.url = "***" }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        let configJSON = (try? String(data: enc.encode(config), encoding: .utf8)) ?? "{}"
        let isoDate = SharedDateFormatters.iso8601FullDate.string(from: Date()).prefix(10)
        let content = "# sage-bar diagnostics \(isoDate)\n\n## Errors (last 100)\n\(errors)\n\n## Config\n\(configJSON)\n"
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("sage-bar-diagnostics-\(isoDate).txt")
        do {
            try content.write(to: dest, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            ErrorLogger.shared.log("Export diagnostics failed: \(error.localizedDescription)")
        }
    }

    @objc private func exportAllActiveAccountsCSV() {
        let config = ConfigManager.shared.load()
        let accounts = Account.activeAccounts(in: config)
        do {
            _ = try UsageReportingService.exportCSV(for: accounts)
        } catch {
            ErrorLogger.shared.log("Export active accounts CSV failed: \(error.localizedDescription)")
        }
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            presentPopover()
        }
    }

    @objc func presentPopover() {
        showStatusMenu()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        showStatusMenu()
    }

    private func showStatusMenu() {
        rebuildMainMenu()
        statusItem.menu = mainMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func rebuildMainMenu() {
        mainMenu.removeAllItems()
        let config = ConfigManager.shared.load()
        let active = Account.activeAccounts(in: config)
        let selected = AccountSelectionService.currentAccount(in: active)
        let aggregate = aggregateToday(for: active)

        mainMenu.addItem(disabledMenuItem("Sage Bar", isHeader: true))
        mainMenu.addItem(disabledMenuItem(accountsOverviewTitle(active: active)))
        mainMenu.addItem(disabledMenuItem(todaySummaryTitle(aggregate: aggregate)))
        if active.count > 1 {
            mainMenu.addItem(disabledMenuItem(selectedAccountTitle(selected, active: active)))
        }
        mainMenu.addItem(disabledMenuItem(lastSyncTitle()))
        mainMenu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        mainMenu.addItem(refreshItem)

        mainMenu.addItem(submenuItem("Accounts", submenu: accountMenu(active: active, selected: selected)))
        mainMenu.addItem(submenuItem("Display", submenu: displayMenu(config: config)))
        mainMenu.addItem(submenuItem("Providers", submenu: providersMenu(active: active)))
        mainMenu.addItem(submenuItem("Insights", submenu: insightsMenu(config: config, active: active, aggregate: aggregate)))
        mainMenu.addItem(submenuItem("Alerts", submenu: alertsMenu(config: config, selected: selected)))
        mainMenu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy Today Summary", action: #selector(copyTodaySummary), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command, .shift]
        copyItem.target = self
        copyItem.isEnabled = !active.isEmpty
        mainMenu.addItem(copyItem)

        let exportUsageItem = NSMenuItem(title: "Export CSV…", action: #selector(exportAllActiveAccountsCSV), keyEquivalent: "")
        exportUsageItem.target = self
        exportUsageItem.isEnabled = !active.isEmpty
        mainMenu.addItem(exportUsageItem)

        let diagnosticsItem = NSMenuItem(title: "Export Diagnostics…", action: #selector(exportDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        mainMenu.addItem(diagnosticsItem)

        let historyItem = NSMenuItem(title: "History", action: #selector(showHistory), keyEquivalent: "h")
        historyItem.keyEquivalentModifierMask = [.command, .shift]
        historyItem.target = self
        historyItem.isEnabled = selected != nil
        mainMenu.addItem(historyItem)
        mainMenu.addItem(.separator())

        let revealDataItem = NSMenuItem(title: "Reveal Data Folder", action: #selector(revealDataFolder), keyEquivalent: "")
        revealDataItem.target = self
        mainMenu.addItem(revealDataItem)
        mainMenu.addItem(disabledMenuItem(versionTitle()))

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        mainMenu.addItem(settingsItem)

        let setupItem = NSMenuItem(title: "Run Setup Wizard", action: #selector(runSetupWizard), keyEquivalent: "")
        setupItem.target = self
        mainMenu.addItem(setupItem)

        let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkItem.target = self
        mainMenu.addItem(checkItem)
        mainMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Sage Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(quitItem)
    }

    @objc private func refreshNow() { PollingService.shared.forceRefresh() }
    @objc private func copyTodaySummary() {
        let active = Account.activeAccounts(in: ConfigManager.shared.load())
        guard !active.isEmpty else { return }
        _ = UsageReportingService.copySummaryToPasteboard(for: active)
    }
    @objc private func showHistory() {
        let active = Account.activeAccounts(in: ConfigManager.shared.load())
        HistoryWindowController.shared.showWindow(
            account: AccountSelectionService.currentAccount(in: active) ?? active.first
        )
    }
    @objc private func openSettings() { SettingsWindowController.shared.showWindow() }
    @objc private func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppConstants.sharedContainerURL])
    }
    @objc private func runSetupWizard() { OnboardingWindowController.shared.showWindow(force: true) }
    @objc private func openAccountFromMenu(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let accountID = UUID(uuidString: rawID) else { return }
        AccountSelectionService.select(accountID: accountID)
        Task { await updateTitle(config: ConfigManager.shared.load()) }
    }
    @objc private func selectNextAccountFromMenu() {
        selectNextAccountAndPresent()
    }
    @objc private func selectPreviousAccountFromMenu() {
        selectPreviousAccountAndPresent()
    }

    @objc private func setDisplayStyleFromMenu(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String else { return }
        var config = ConfigManager.shared.load()
        config.display.menubarStyle = style
        _ = ConfigManager.shared.save(config)
        Task { await updateTitle(config: config) }
    }

    @objc private func toggleBadgeFromMenu() {
        var config = ConfigManager.shared.load()
        config.display.showBadge.toggle()
        _ = ConfigManager.shared.save(config)
        Task { await updateTitle(config: config) }
    }

    @objc private func toggleSparklineFromMenu() {
        var config = ConfigManager.shared.load()
        config.sparkline.enabled.toggle()
        _ = ConfigManager.shared.save(config)
        Task { await updateTitle(config: config) }
    }

    @objc private func toggleDualIconFromMenu() {
        var config = ConfigManager.shared.load()
        config.display.dualIcon.toggle()
        _ = ConfigManager.shared.save(config)
        Task {
            await updateTitle(config: config)
            await updateDualIcon(config: config)
        }
    }

    @objc private func configureAlerts() {
        SettingsWindowController.shared.showWindow()
    }

    private func accountMenu(active: [Account], selected: Account?) -> NSMenu {
        let menu = NSMenu()
        guard !active.isEmpty else {
            menu.addItem(disabledMenuItem("No active accounts"))
            return menu
        }

        for account in active {
            let item = NSMenuItem(
                title: accountMenuTitle(account, active: active),
                action: #selector(openAccountFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account.id.uuidString
            item.state = account.id == selected?.id ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let previous = NSMenuItem(title: "Previous Account", action: #selector(selectPreviousAccountFromMenu), keyEquivalent: "[")
        previous.target = self
        menu.addItem(previous)
        let next = NSMenuItem(title: "Next Account", action: #selector(selectNextAccountFromMenu), keyEquivalent: "]")
        next.target = self
        menu.addItem(next)
        return menu
    }

    private func displayMenu(config: Config) -> NSMenu {
        let menu = NSMenu()
        for option in [
            ("icon", "Icon"),
            ("cost", "Cost"),
            ("tokens", "Tokens"),
        ] {
            let item = NSMenuItem(title: option.1, action: #selector(setDisplayStyleFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.0
            item.state = config.display.menubarStyle == option.0 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let badge = NSMenuItem(title: "Show Status Badge", action: #selector(toggleBadgeFromMenu), keyEquivalent: "")
        badge.target = self
        badge.state = config.display.showBadge ? .on : .off
        menu.addItem(badge)

        let sparkline = NSMenuItem(title: "Show Sparkline", action: #selector(toggleSparklineFromMenu), keyEquivalent: "")
        sparkline.target = self
        sparkline.state = config.sparkline.enabled ? .on : .off
        menu.addItem(sparkline)

        let dualIcon = NSMenuItem(title: "Dual Menu Bar Items", action: #selector(toggleDualIconFromMenu), keyEquivalent: "")
        dualIcon.target = self
        dualIcon.state = config.display.dualIcon ? .on : .off
        dualIcon.isEnabled = Account.activeAccounts(in: config).count <= 2
        menu.addItem(dualIcon)
        return menu
    }

    private func providersMenu(active: [Account]) -> NSMenu {
        let menu = NSMenu()
        guard !active.isEmpty else {
            menu.addItem(disabledMenuItem("No providers active"))
            return menu
        }

        let grouped = Dictionary(grouping: active, by: \.type)
        for type in AccountType.allCases where grouped[type] != nil {
            let accounts = grouped[type] ?? []
            let title = accounts.count == 1 ? type.displayName : "\(type.displayName) (\(accounts.count))"
            let item = disabledMenuItem(title)
            item.state = .on
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Manage Providers…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    private func insightsMenu(config: Config, active: [Account], aggregate: MenuBarUsageAggregate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledMenuItem(topModelTitle(aggregate: aggregate)))
        menu.addItem(disabledMenuItem(budgetRemainingTitle(active: active, aggregate: aggregate)))
        menu.addItem(disabledMenuItem(dataHealthTitle(config: config, aggregate: aggregate)))
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Summary", action: #selector(copyTodaySummary), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = !active.isEmpty
        menu.addItem(copy)
        return menu
    }

    private func alertsMenu(config: Config, selected: Account?) -> NSMenu {
        let menu = NSMenu()
        if let selected {
            let limitText = selected.costLimitUSD.map { String(format: "$%.2f/day", $0) } ?? "No daily limit"
            menu.addItem(disabledMenuItem("Daily Limit: \(limitText)"))
        } else {
            menu.addItem(disabledMenuItem("Daily Limit: No account"))
        }
        menu.addItem(disabledMenuItem(burnRateMenuTitle(config: config, selected: selected)))
        menu.addItem(disabledMenuItem(claudeAIQuotaMenuTitle(config: config)))
        menu.addItem(.separator())
        let configure = NSMenuItem(title: "Configure Alerts…", action: #selector(configureAlerts), keyEquivalent: "")
        configure.target = self
        menu.addItem(configure)
        return menu
    }

    private func submenuItem(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func disabledMenuItem(_ title: String, isHeader: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = isHeader
            ? NSFontManager.shared.convert(NSFont.menuFont(ofSize: 13), toHaveTrait: .boldFontMask)
            : NSFont.menuFont(ofSize: 12)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: isHeader ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    private struct MenuBarUsageAggregate {
        let accountCount: Int
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheCreationTokens: Int
        let totalCacheReadTokens: Int
        let totalCostUSD: Double
        let latestTimestamp: Date?
        let modelBreakdown: [ModelUsage]
        let costConfidence: CostConfidence

        var totalTokens: Int {
            totalInputTokens + totalOutputTokens
        }

        var hasData: Bool {
            latestTimestamp != nil
        }

        func snapshot() -> UsageSnapshot? {
            guard let latestTimestamp else { return nil }
            return UsageSnapshot(
                accountId: UUID(),
                timestamp: latestTimestamp,
                inputTokens: totalInputTokens,
                outputTokens: totalOutputTokens,
                cacheCreationTokens: totalCacheCreationTokens,
                cacheReadTokens: totalCacheReadTokens,
                totalCostUSD: totalCostUSD,
                modelBreakdown: modelBreakdown,
                costConfidence: costConfidence
            )
        }
    }

    private func aggregateToday(for accounts: [Account]) -> MenuBarUsageAggregate {
        let aggregates = accounts.map { CacheManager.shared.todayAggregate(forAccount: $0.id) }
        return makeAggregate(accountCount: accounts.count, dailyAggregates: aggregates)
    }

    private func aggregateTodayAsync(for accounts: [Account]) async -> MenuBarUsageAggregate {
        var aggregates: [DailyAggregate] = []
        aggregates.reserveCapacity(accounts.count)
        for account in accounts {
            aggregates.append(await CacheManager.shared.todayAggregateAsync(forAccount: account.id))
        }
        return makeAggregate(accountCount: accounts.count, dailyAggregates: aggregates)
    }

    private func makeAggregate(
        accountCount: Int,
        dailyAggregates: [DailyAggregate]
    ) -> MenuBarUsageAggregate {
        let snapshots = dailyAggregates.flatMap(\.snapshots)
        let modelRows = snapshots.flatMap { $0.modelBreakdown }
        let groupedModels = Dictionary(grouping: modelRows) { $0.modelId }
        let unsortedModels = groupedModels.map { modelId, rows in
            ModelUsage(
                modelId: modelId,
                inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
                outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
                cacheTokens: rows.reduce(0) { $0 + $1.cacheTokens },
                costUSD: rows.reduce(0) { $0 + $1.costUSD }
            )
        }
        let models = unsortedModels.sorted { lhs, rhs in
            let lhsTokens = lhs.inputTokens + lhs.outputTokens + lhs.cacheTokens
            let rhsTokens = rhs.inputTokens + rhs.outputTokens + rhs.cacheTokens
            return lhsTokens > rhsTokens
        }
        let hasEstimatedCost = snapshots.contains { $0.costConfidence == .estimated }
        return MenuBarUsageAggregate(
            accountCount: accountCount,
            totalInputTokens: dailyAggregates.reduce(0) { $0 + $1.totalInputTokens },
            totalOutputTokens: dailyAggregates.reduce(0) { $0 + $1.totalOutputTokens },
            totalCacheCreationTokens: snapshots.reduce(0) { $0 + $1.cacheCreationTokens },
            totalCacheReadTokens: snapshots.reduce(0) { $0 + $1.cacheReadTokens },
            totalCostUSD: dailyAggregates.reduce(0) { $0 + $1.totalCostUSD },
            latestTimestamp: snapshots.map(\.timestamp).max(),
            modelBreakdown: models,
            costConfidence: hasEstimatedCost ? .estimated : .billingGrade
        )
    }

    private func accountsOverviewTitle(active: [Account]) -> String {
        switch active.count {
        case 0:
            return "No active accounts"
        case 1:
            return "1 active account"
        default:
            return "\(active.count) active accounts"
        }
    }

    private func selectedAccountTitle(_ selected: Account?, active: [Account]) -> String {
        guard let selected else { return "Selected: None" }
        return "Selected: \(selected.displayLabel(among: active))"
    }

    private func todaySummaryTitle(aggregate: MenuBarUsageAggregate) -> String {
        "\(String(format: "$%.4f", aggregate.totalCostUSD)) today, \(formatCount(aggregate.totalTokens)) tokens"
    }

    private func lastSyncTitle() -> String {
        guard let date = PollingService.shared.lastPollDate else { return "Last synced: Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last synced: \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func versionTitle() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Version \(version?.isEmpty == false ? version! : "1.0.0")"
    }

    private func accountMenuTitle(_ account: Account, active: [Account]) -> String {
        let aggregate = CacheManager.shared.todayAggregate(forAccount: account.id)
        let cost = account.type == .githubCopilot || account.type == .claudeAI
            ? "n/a"
            : String(format: "$%.2f", aggregate.totalCostUSD)
        return "\(account.displayLabel(among: active))  \(cost)"
    }

    private func topModelTitle(aggregate: MenuBarUsageAggregate) -> String {
        guard let model = aggregate.modelBreakdown.first else {
            return "Top Model: No data"
        }
        return "Top Model: \(shortModelName(model.modelId))"
    }

    private func budgetRemainingTitle(active: [Account], aggregate: MenuBarUsageAggregate) -> String {
        let totalLimit = active.compactMap(\.costLimitUSD).reduce(0, +)
        guard totalLimit > 0 else { return "Budget: No daily limits" }
        return "Budget Left: \(String(format: "$%.2f", max(0, totalLimit - aggregate.totalCostUSD)))"
    }

    private func dataHealthTitle(config: Config, aggregate: MenuBarUsageAggregate) -> String {
        guard let latestTimestamp = aggregate.latestTimestamp else {
            return "Data Health: No data"
        }
        let age = Date().timeIntervalSince(latestTimestamp)
        let threshold = TimeInterval(config.pollIntervalSeconds * 2)
        return age > threshold ? "Data Health: Stale" : "Data Health: Current"
    }

    private func burnRateMenuTitle(config: Config, selected: Account?) -> String {
        guard config.burnRate.enabled else { return "Burn Rate: Off" }
        guard let selected else { return "Burn Rate: No account" }
        let current = PollingService.shared.burnRateUSDPerHourByAccount[selected.id]
        let threshold = PollingService.shared.burnRateThresholdUSDPerHourByAccount[selected.id]
            ?? config.burnRate.perAccountUSDPerHourThreshold[selected.id.uuidString]
            ?? config.burnRate.defaultUSDPerHourThreshold
        let currentText = current.map { String(format: "$%.2f/h", $0) } ?? "No data"
        return "Burn Rate: \(currentText) / \(String(format: "$%.2f/h", threshold))"
    }

    private func claudeAIQuotaMenuTitle(config: Config) -> String {
        let claudeAccounts = Account.activeAccounts(in: config).filter { $0.type == .claudeAI }
        guard !claudeAccounts.isEmpty else { return "Claude AI Quota: No account" }
        let threshold = config.claudeAI.lowMessagesThreshold
        return config.claudeAI.notifyOnLowMessages
            ? "Claude AI Quota: On (≤\(threshold))"
            : "Claude AI Quota: Off"
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return "\(value / 1_000)k"
        }
        return "\(value)"
    }

    private func shortModelName(_ modelID: String) -> String {
        let cleaned = modelID
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-latest", with: "")
            .replacingOccurrences(of: "models/", with: "")
        return cleaned.count > 24 ? "\(cleaned.prefix(21))…" : cleaned
    }

    private func onUsageUpdate(_ notif: Notification) async {
        let config = ConfigManager.shared.load()
        // update button title
        await updateTitle(config: config)
        // stale data check
        await checkStaleness(config: config)
        // sparkline (throttled 5s)
        if config.sparkline.enabled {
            throttleWorkItem?.cancel()
            let wi = DispatchWorkItem { [weak self] in
                Task { await self?.redrawSparkline(config: config) }
            }
            throttleWorkItem = wi
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: wi)
        }
        // refresh popover content if open
        if popover.isShown {
            popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView())
        }
        // dual icon
        await updateDualIcon(config: config)
    }

    private func updateTitle(config: Config) async {
        guard let btn = statusItem.button else { return }
        var baseTitle = ""
        var baseImage: NSImage?
        let activeAccounts = Account.activeAccounts(in: config)
        let aggregate = await aggregateTodayAsync(for: activeAccounts)
        let snap = aggregate.snapshot()
        switch config.display.menubarStyle {
        case "cost":
            baseTitle = String(format: "$%.2f", aggregate.totalCostUSD)
        case "tokens":
            baseTitle = formatCount(aggregate.totalTokens)
        default: // "icon"
            let health = currentHealth(config: config, aggregate: aggregate)
            baseImage = MenuBarIconRenderer.renderFromSnapshot(snap, health: health)
        }
        btn.title = baseTitle
        btn.image = baseImage
        await applyClaudeAIStatusBadge(config: config, button: btn)
    }

    private func currentHealth(config: Config, aggregate: MenuBarUsageAggregate) -> HealthDot {
        guard let latestTimestamp = aggregate.latestTimestamp else { return .error }
        let age = Date().timeIntervalSince(latestTimestamp)
        if age > TimeInterval(config.pollIntervalSeconds * 2) { return .error }
        if aggregate.costConfidence == .estimated { return .estimated }
        return .healthy
    }

    private func checkStaleness(config: Config) async {
        guard let btn = statusItem.button else { return }
        let activeAccounts = Account.activeAccounts(in: config)
        let aggregate = await aggregateTodayAsync(for: activeAccounts)
        guard let snap = aggregate.snapshot() else {
            btn.appearsDisabled = config.display.showBadge
            return
        }
        let age = Date().timeIntervalSince(snap.timestamp)
        let threshold = TimeInterval(config.pollIntervalSeconds * 2)
        if age > threshold && config.display.showBadge {
            btn.image = MenuBarIconRenderer.renderFromSnapshot(snap, health: .error)
            btn.appearsDisabled = true
        } else {
            btn.appearsDisabled = false
        }
    }

    // MARK: – Sparkline

    func updateSparklineIcon(snapshots: [UsageSnapshot], config: SparklineConfig) {
        guard config.enabled, snapshots.count >= 2 else { return }
        let values: [Double] = snapshots.map {
            config.style == "cost" ? $0.totalCostUSD : Double($0.inputTokens + $0.outputTokens)
        }
        let img = MenuBarSparklineImage.render(values: values)
        statusItem.button?.image = img
    }

    private func redrawSparkline(config: Config) async {
        let activeAccounts = Account.activeAccounts(in: config)
        guard !activeAccounts.isEmpty else { return }
        var snapshots: [UsageSnapshot] = []
        snapshots.reserveCapacity(activeAccounts.count * 24)
        for account in activeAccounts {
            let history = await CacheManager.shared.historyAsync(
                forAccount: account.id,
                days: config.sparkline.windowHours / 24 + 1
            )
            snapshots.append(contentsOf: history)
        }
        updateSparklineIcon(snapshots: snapshots.sorted { $0.timestamp < $1.timestamp }, config: config.sparkline)
    }

    // MARK: – Dual icon


    private func updateDualIcon(config: Config) async {
        let active = Account.activeAccounts(in: config)
        if config.display.dualIcon, active.count > 2 {
            secondStatusItem.map { NSStatusBar.system.removeStatusItem($0) }
            secondStatusItem = nil
            var updated = config
            updated.display.dualIcon = false
            _ = ConfigManager.shared.save(updated)
            ErrorLogger.shared.log("Dual icon mode auto-disabled because more than 2 active accounts are enabled", level: "WARN")
            return
        }
        guard config.display.dualIcon, active.count == 2 else {
            secondStatusItem.map { NSStatusBar.system.removeStatusItem($0) }
            secondStatusItem = nil
            return
        }
        if secondStatusItem == nil {
            secondStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            secondStatusItem?.button?.action = #selector(togglePopover)
            secondStatusItem?.button?.target = self
        }
        let account2 = active[1]
        if let snap = await CacheManager.shared.latestAsync(forAccount: account2.id) {
            switch config.display.menubarStyle {
            case "cost": secondStatusItem?.button?.title = String(format: "$%.2f", snap.totalCostUSD)
            case "tokens":
                let t = snap.inputTokens + snap.outputTokens
                secondStatusItem?.button?.title = t >= 1000 ? "\(t / 1000)k" : "\(t)"
            default:
                let health = snap.costConfidence == .estimated ? HealthDot.estimated : .healthy
                secondStatusItem?.button?.image = MenuBarIconRenderer.renderFromSnapshot(snap, health: health)
            }
        }
    }

    private func applyClaudeAIStatusBadge(config: Config, button: NSStatusBarButton) async {
        guard config.display.showBadge else { return }
        let claudeAIAccounts = Account.activeAccounts(in: config).filter { $0.type == .claudeAI }
        guard !claudeAIAccounts.isEmpty else { return }
        var requiresReauth = false
        var hasLowQuota = false
        for account in claudeAIAccounts {
            guard let status = await ClaudeAIStatusStore.shared.status(for: account.id) else { continue }
            if status.sessionHealth == .reauthRequired {
                requiresReauth = true
                break
            }
            if status.messagesRemaining <= config.claudeAI.lowMessagesThreshold {
                hasLowQuota = true
            }
        }
        guard requiresReauth || hasLowQuota else { return }
        if config.display.menubarStyle == "icon" {
            let symbolName = requiresReauth ? "key.fill" : "exclamationmark.triangle.fill"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Claude AI warning")
            button.image?.isTemplate = true
            button.title = ""
        } else if !button.title.hasPrefix("!") {
            button.title = "!\(button.title)"
        }
    }

    @MainActor
    func selectNextAccountAndPresent() {
        let activeAccounts = Account.activeAccounts(in: ConfigManager.shared.load())
        guard AccountSelectionService.selectNext(in: activeAccounts) != nil else { return }
        if !popover.isShown {
            togglePopover()
        } else {
            popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView())
        }
    }

    @MainActor
    func selectPreviousAccountAndPresent() {
        let activeAccounts = Account.activeAccounts(in: ConfigManager.shared.load())
        guard AccountSelectionService.selectPrevious(in: activeAccounts) != nil else { return }
        if !popover.isShown {
            togglePopover()
        } else {
            popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView())
        }
    }
}
