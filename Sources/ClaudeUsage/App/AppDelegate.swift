import AppKit
import Foundation
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var updaterController: SPUStandardUpdaterController?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = dockIconImage() {
            NSApp.applicationIconImage = icon
        } else {
            ErrorLogger.shared.log("Failed to load app icon from bundle", level: "WARN")
        }
        NSApp.setActivationPolicy(.accessory)

        if shouldEnableSparkleUpdater {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            // check for updates immediately on launch
            updaterController?.updater.checkForUpdatesInBackground()
            // daily update check timer
            updateTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
                self?.updaterController?.updater.checkForUpdatesInBackground()
            }
        } else {
            updaterController = nil
            updateTimer = nil
        }

        // setup menu bar
        MenuBarManager.shared.setup(updaterController: updaterController)

        // setup wizard on first run or after setup-state upgrades
        OnboardingWindowController.shared.showWindow()

        // request notification permission once
        NotificationManager.shared.requestPermission()

        // register global hotkey
        let config = ConfigManager.shared.load()
        if config.hotkey.enabled {
            HotkeyManager.shared.register(config: config.hotkey, advancedConfig: config.hotkeyConfig)
        }

        // start log watcher
        ClaudeCodeLogParser.shared.startWatching()
        CodexLogParser.shared.startWatching()
        GeminiLogParser.shared.startWatching()

        // start iCloud metadata query
        if config.iCloudSync.enabled {
            iCloudSyncManager.shared.startMetadataQuery(config: config.iCloudSync)
        }

        // start polling
        Task { @MainActor in
            PollingService.shared.start(config: config)
        }
        ErrorLogger.shared.log("App launched, \(config.accounts.filter(\.isActive).count) active accounts", level: "INFO")
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        HotkeyManager.shared.unregisterAll()
        PollingService.shared.stop()
        iCloudSyncManager.shared.stopMetadataQuery()
    }

    private var shouldEnableSparkleUpdater: Bool {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else { return false }
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return false }
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.isEmpty,
              URL(string: feedURL) != nil else {
            return false
        }
        return true
    }

    private func dockIconImage() -> NSImage? {
        let candidates = [
            ("WizardDockIcon", "png"),
            ("AppIcon", "icns"),
            ("AppIcon", "png"),
        ]
        for (name, ext) in candidates {
            if let url = Bundle.module.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}
