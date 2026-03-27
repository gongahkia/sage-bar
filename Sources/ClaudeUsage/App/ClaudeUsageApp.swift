import SwiftUI
import AppKit

@main
struct SageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() } // no main window; agent-only app
    }
}
