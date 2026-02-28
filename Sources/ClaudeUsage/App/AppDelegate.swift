import AppKit
import Foundation
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // suppress Dock icon

        // check for updates immediately on launch
        updaterController.updater.checkForUpdatesInBackground()

        // daily update check timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.updaterController.updater.checkForUpdatesInBackground()
        }

        // setup menu bar
        MenuBarManager.shared.setup(updaterController: updaterController)

        // request notification permission once
        NotificationManager.shared.requestPermission()

        // register global hotkey
        let config = ConfigManager.shared.load()
        if config.hotkey.enabled {
            HotkeyManager.shared.register(config: config.hotkey)
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        HotkeyManager.shared.unregisterAll()
        PollingService.shared.stop()
    }
}
