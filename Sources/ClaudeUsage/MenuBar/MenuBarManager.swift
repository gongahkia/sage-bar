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
        guard statusItem.button != nil else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            presentPopover()
        }
    }

    @objc func presentPopover() {
        guard let btn = statusItem.button else { return }
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
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
        // header
        let titleItem = NSMenuItem(title: "Sage Bar", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = NSAttributedString(string: "Sage Bar", attributes: [.font: NSFontManager.shared.convert(NSFont.menuFont(ofSize: 13), toHaveTrait: .boldFontMask)])
        mainMenu.addItem(titleItem)
        if let date = PollingService.shared.lastPollDate {
            let fmt = RelativeDateTimeFormatter(); fmt.unitsStyle = .abbreviated
            let ago = fmt.localizedString(for: date, relativeTo: Date())
            let sub = NSMenuItem(title: "Last synced: \(ago)", action: nil, keyEquivalent: "")
            sub.attributedTitle = NSAttributedString(string: "Last synced: \(ago)", attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            mainMenu.addItem(sub)
        }
        mainMenu.addItem(.separator())
        let pinnedAccounts = active.filter(\.isPinned)
        if !pinnedAccounts.isEmpty {
            let pinnedHeader = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            pinnedHeader.isEnabled = false
            mainMenu.addItem(pinnedHeader)
            for account in pinnedAccounts {
                let item = NSMenuItem(title: account.displayLabel(among: active), action: #selector(openAccountFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.id.uuidString
                item.state = account.id == selected?.id ? .on : .off
                mainMenu.addItem(item)
            }
            mainMenu.addItem(.separator())
        }
        // per-account usage
        if active.isEmpty {
            let noAcct = NSMenuItem(title: "No active accounts", action: nil, keyEquivalent: "")
            noAcct.isEnabled = false
            mainMenu.addItem(noAcct)
        }
        for account in active {
            let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
            let costStr = String(format: "$%.4f", agg.totalCostUSD)
            let tokens = agg.totalInputTokens + agg.totalOutputTokens
            let unit: String
            switch account.type {
            case .githubCopilot: unit = "activities"
            case .claudeAI: unit = "messages"
            default: unit = "tokens"
            }
            let tokStr = tokens >= 1000 ? "\(tokens / 1000)k \(unit)" : "\(tokens) \(unit)"
            let costLabel: String
            switch account.type {
            case .githubCopilot, .claudeAI: costLabel = "n/a"
            case .windsurfEnterprise: costLabel = "\(costStr) est."
            default: costLabel = costStr
            }
            let displayName = account.displayLabel(among: active)
            let acctItem = NSMenuItem(title: "\(displayName)  —  \(costLabel)", action: nil, keyEquivalent: "")
            acctItem.attributedTitle = NSAttributedString(string: "\(displayName)  —  \(costLabel)", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            acctItem.state = account.id == selected?.id ? .on : .off
            mainMenu.addItem(acctItem)
            let detail = NSMenuItem(title: "\(tokStr)  ·  \(account.type.rawValue)", action: nil, keyEquivalent: "")
            detail.attributedTitle = NSAttributedString(string: "\(tokStr)  ·  \(account.type.displayName)", attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            detail.indentationLevel = 1
            mainMenu.addItem(detail)
        }
        mainMenu.addItem(.separator())
        // actions
        let setupItem = NSMenuItem(title: "Run Setup Wizard", action: #selector(runSetupWizard), keyEquivalent: "")
        setupItem.target = self
        mainMenu.addItem(setupItem)
        let nextAccountItem = NSMenuItem(title: "Next Account", action: #selector(selectNextAccountFromMenu), keyEquivalent: "]")
        nextAccountItem.target = self
        mainMenu.addItem(nextAccountItem)
        let previousAccountItem = NSMenuItem(title: "Previous Account", action: #selector(selectPreviousAccountFromMenu), keyEquivalent: "[")
        previousAccountItem.target = self
        mainMenu.addItem(previousAccountItem)
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        mainMenu.addItem(refreshItem)
        let exportUsageItem = NSMenuItem(title: "Export All Active Accounts CSV…", action: #selector(exportAllActiveAccountsCSV), keyEquivalent: "")
        exportUsageItem.target = self
        mainMenu.addItem(exportUsageItem)
        mainMenu.addItem(.separator())
        let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkItem.target = self
        mainMenu.addItem(checkItem)
        mainMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Sage Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(quitItem)
    }

    @objc private func refreshNow() { PollingService.shared.forceRefresh() }
    @objc private func runSetupWizard() { OnboardingWindowController.shared.showWindow(force: true) }
    @objc private func openAccountFromMenu(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let accountID = UUID(uuidString: rawID) else { return }
        AccountSelectionService.select(accountID: accountID)
        togglePopover()
    }
    @objc private func selectNextAccountFromMenu() {
        selectNextAccountAndPresent()
    }
    @objc private func selectPreviousAccountFromMenu() {
        selectPreviousAccountAndPresent()
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
        let snap = await firstActiveSnapshot(config: config)
        switch config.display.menubarStyle {
        case "cost":
            if let snap { baseTitle = String(format: "$%.2f", snap.totalCostUSD) }
        case "tokens":
            if let snap {
                let total = snap.inputTokens + snap.outputTokens
                baseTitle = total >= 1000 ? "\(total / 1000)k" : "\(total)"
            }
        default: // "icon"
            let health = await currentHealth(config: config)
            baseImage = MenuBarIconRenderer.renderFromSnapshot(snap, health: health)
        }
        btn.title = baseTitle
        btn.image = baseImage
        await applyClaudeAIStatusBadge(config: config, button: btn)
    }

    private func currentHealth(config: Config) async -> HealthDot {
        guard let snap = await firstActiveSnapshot(config: config) else { return .error }
        let age = Date().timeIntervalSince(snap.timestamp)
        if age > TimeInterval(config.pollIntervalSeconds * 2) { return .error }
        if snap.costConfidence == .estimated { return .estimated }
        return .healthy
    }

    private func firstActiveSnapshot(config: Config) async -> UsageSnapshot? {
        let activeAccounts = Account.activeAccounts(in: config)
        guard let account = AccountSelectionService.currentAccount(in: activeAccounts) ?? activeAccounts.first else { return nil }
        return await CacheManager.shared.latestAsync(forAccount: account.id)
    }

    private func checkStaleness(config: Config) async {
        guard let snap = await firstActiveSnapshot(config: config),
              let btn = statusItem.button else { return }
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
        guard let account = AccountSelectionService.currentAccount(in: activeAccounts) ?? activeAccounts.first else { return }
        let snaps = await CacheManager.shared.historyAsync(
            forAccount: account.id,
            days: config.sparkline.windowHours / 24 + 1
        )
        updateSparklineIcon(snapshots: snaps, config: config.sparkline)
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
