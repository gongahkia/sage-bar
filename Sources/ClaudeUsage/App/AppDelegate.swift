import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // suppress Dock icon

        // setup menu bar
        MenuBarManager.shared.setup()

        // request notification permission once
        NotificationManager.shared.requestPermission()

        // register global hotkey
        let config = ConfigManager.shared.load()
        if config.hotkey.enabled {
            HotkeyManager.shared.register(config: config.hotkey)
        }

        // start log watcher
        ClaudeCodeLogParser.shared.startWatching()

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
        HotkeyManager.shared.unregister()
        PollingService.shared.stop()
    }
}
