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
            btn.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Sage Bar")
            btn.image?.isTemplate = true
            btn.action = #selector(handleStatusItemClick(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        contextMenu.removeAllItems()
        for item in buildContextMenu().items {
            contextMenu.addItem(item)
        }
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 480)
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
        let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)
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

    @objc func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
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
        let active = config.accounts.filter(\.isActive).sorted {
            $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order
        }
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
            let unit = account.type == .githubCopilot ? "activities" : "tokens"
            let tokStr = tokens >= 1000 ? "\(tokens / 1000)k \(unit)" : "\(tokens) \(unit)"
            let costLabel = account.type == .githubCopilot ? "n/a" : costStr
            let acctItem = NSMenuItem(title: "\(account.name)  —  \(costLabel)", action: nil, keyEquivalent: "")
            acctItem.attributedTitle = NSAttributedString(string: "\(account.name)  —  \(costLabel)", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            mainMenu.addItem(acctItem)
            let detail = NSMenuItem(title: "\(tokStr)  ·  \(account.type.rawValue)", action: nil, keyEquivalent: "")
            detail.attributedTitle = NSAttributedString(string: "\(tokStr)  ·  \(account.type.displayName)", attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            detail.indentationLevel = 1
            mainMenu.addItem(detail)
        }
        mainMenu.addItem(.separator())
        // actions
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        mainMenu.addItem(refreshItem)
        mainMenu.addItem(.separator())
        // open sage bar (lockout-style)
        let openItem = NSMenuItem(title: "Open Sage Bar…", action: #selector(openSageBar), keyEquivalent: "o")
        openItem.target = self
        mainMenu.addItem(openItem)
        let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkItem.target = self
        mainMenu.addItem(checkItem)
        mainMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Sage Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(quitItem)
    }

    @objc private func refreshNow() { PollingService.shared.forceRefresh() }
    @objc private func openSageBar() { SettingsWindowController.shared.showWindow() }

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
        switch config.display.menubarStyle {
        case "cost":
            if let snap = await firstActiveSnapshot(config: config) {
                btn.title = String(format: "$%.2f", snap.totalCostUSD)
                btn.image = nil
            }
        case "tokens":
            if let snap = await firstActiveSnapshot(config: config) {
                let total = snap.inputTokens + snap.outputTokens
                btn.title = total >= 1000 ? "\(total / 1000)k" : "\(total)"
                btn.image = nil
            }
        default: // "icon"
            btn.title = ""
            btn.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)
            btn.image?.isTemplate = true
        }
    }

    private func firstActiveSnapshot(config: Config) async -> UsageSnapshot? {
        guard let account = config.accounts.first(where: { $0.isActive }) else { return nil }
        return await CacheManager.shared.latestAsync(forAccount: account.id)
    }

    private func checkStaleness(config: Config) async {
        guard let snap = await firstActiveSnapshot(config: config),
              let btn = statusItem.button else { return }
        let age = Date().timeIntervalSince(snap.timestamp)
        let threshold = TimeInterval(config.pollIntervalSeconds * 2)
        if age > threshold && config.display.showBadge {
            // orange dot badge via attributed string overlay
            let img = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)
            img?.isTemplate = true
            btn.image = img
            btn.appearsDisabled = true // visual cue
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
        guard let account = config.accounts.first(where: { $0.isActive }) else { return }
        let snaps = await CacheManager.shared.historyAsync(
            forAccount: account.id,
            days: config.sparkline.windowHours / 24 + 1
        )
        updateSparklineIcon(snapshots: snaps, config: config.sparkline)
    }

    // MARK: – Dual icon


    private func updateDualIcon(config: Config) async {
        let active = config.accounts.filter { $0.isActive }
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
                secondStatusItem?.button?.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)
            }
        }
    }
}
