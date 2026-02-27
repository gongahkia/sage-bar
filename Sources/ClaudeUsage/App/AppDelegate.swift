import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // suppress Dock icon
    }
    func applicationWillTerminate(_ notification: Notification) {}
}
