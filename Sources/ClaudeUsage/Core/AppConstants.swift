import Foundation

enum AppConstants {
    static let appGroupIdentifier = "group.dev.claudeusage"
    static let bundleIdentifier = "dev.claudeusage.ClaudeUsage"
    static let keychainService = "claude-usage"
    static let keychainSessionTokenService = "claude-usage-session-token" // for claudeAI account session cookies
    static let selectedAccountDefaultsKey = "menubarSelectedAccountID"

    /// shared container URL between ClaudeUsage.app and claude-usage CLI
    static let sharedContainerURL: URL = {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            // fallback to tmp when not code-signed (dev mode)
            return FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage")
        }
        return url
    }()
}
