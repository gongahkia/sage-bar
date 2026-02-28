import AppKit
import SwiftUI
import Combine
import Sparkle

class MenuBarManager {
    static let shared = MenuBarManager()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let contextMenu = NSMenu()
    private var monitor: Any?
    private var throttleWorkItem: DispatchWorkItem?
    private var secondStatusItem: NSStatusItem? // dual icon support
    private(set) var updaterController: SPUStandardUpdaterController?

    private init() {}

    func setup(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Claude Usage")
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
            self?.onUsageUpdate(notif)
        }
        NotificationCenter.default.addObserver(
            forName: .claudeCodeLogsChanged, object: nil, queue: .main
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
        let errors = ErrorLogger.shared.readLast(100).joined(separator: "\n")
        var config = ConfigManager.shared.load()
        // sanitize sensitive fields
        if !config.webhook.url.isEmpty { config.webhook.url = "***" }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        let configJSON = (try? String(data: enc.encode(config), encoding: .utf8)) ?? "{}"
        let isoDate = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let content = "# claude-usage diagnostics \(isoDate)\n\n## Errors (last 100)\n\(errors)\n\n## Config\n\(configJSON)\n"
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("claude-usage-diagnostics-\(isoDate).txt")
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
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        let isRightClick = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if isRightClick {
            NSMenu.popUpContextMenu(contextMenu, with: event, for: sender)
        } else {
            togglePopover()
        }
    }

    private func onUsageUpdate(_ notif: Notification) {
        let config = ConfigManager.shared.load()
        // update button title
        updateTitle(config: config)
        // stale data check
        checkStaleness(config: config)
        // sparkline (throttled 5s)
        if config.sparkline.enabled {
            throttleWorkItem?.cancel()
            let wi = DispatchWorkItem { [weak self] in self?.redrawSparkline(config: config) }
            throttleWorkItem = wi
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: wi)
        }
        // refresh popover content if open
        if popover.isShown {
            popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView())
        }
        // dual icon
        updateDualIcon(config: config)
    }

    private func updateTitle(config: Config) {
        guard let btn = statusItem.button else { return }
        switch config.display.menubarStyle {
        case "cost":
            if let snap = firstActiveSnapshot(config: config) {
                btn.title = String(format: "$%.2f", snap.totalCostUSD)
                btn.image = nil
            }
        case "tokens":
            if let snap = firstActiveSnapshot(config: config) {
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

    private func firstActiveSnapshot(config: Config) -> UsageSnapshot? {
        config.accounts.first(where: { $0.isActive })
            .flatMap { CacheManager.shared.latest(forAccount: $0.id) }
    }

    private func checkStaleness(config: Config) {
        guard let snap = firstActiveSnapshot(config: config),
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
        guard config.enabled else { return }
        let values: [Double] = snapshots.map {
            config.style == "cost" ? $0.totalCostUSD : Double($0.inputTokens + $0.outputTokens)
        }
        let img = MenuBarSparklineImage.render(values: values)
        statusItem.button?.image = img
    }

    private func redrawSparkline(config: Config) {
        guard let account = config.accounts.first(where: { $0.isActive }) else { return }
        let snaps = CacheManager.shared.history(forAccount: account.id, days: config.sparkline.windowHours / 24 + 1)
        updateSparklineIcon(snapshots: snaps, config: config.sparkline)
    }

    // MARK: – Dual icon

    private func updateDualIcon(config: Config) {
        let active = config.accounts.filter { $0.isActive }
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
        if let snap = CacheManager.shared.latest(forAccount: account2.id) {
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
