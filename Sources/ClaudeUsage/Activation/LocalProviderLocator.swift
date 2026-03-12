import AppKit
import Foundation

struct LocalProviderSourceStatus: Equatable {
    let accountType: AccountType
    let resolvedDirectory: URL
    let defaultDirectory: URL
    let isUsingOverride: Bool
    let exists: Bool
    let isDirectory: Bool

    var isAvailable: Bool {
        exists && isDirectory
    }

    var displayPath: String {
        resolvedDirectory.path
    }
}

enum LocalProviderLocator {
    static func defaultDirectory(for type: AccountType) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch type {
        case .claudeCode:
            return home.appendingPathComponent(".claude").appendingPathComponent("projects")
        case .codex:
            return home.appendingPathComponent(".codex").appendingPathComponent("sessions")
        case .gemini:
            return home.appendingPathComponent(".gemini").appendingPathComponent("tmp")
        default:
            return nil
        }
    }

    static func status(for account: Account) -> LocalProviderSourceStatus? {
        status(for: account.type, overridePath: account.trimmedLocalDataPath)
    }

    static func status(for type: AccountType, overridePath: String?) -> LocalProviderSourceStatus? {
        guard let defaultDirectory = defaultDirectory(for: type) else { return nil }
        let resolvedDirectory: URL
        let isUsingOverride: Bool
        if let overridePath = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines), !overridePath.isEmpty {
            resolvedDirectory = URL(fileURLWithPath: overridePath).standardizedFileURL
            isUsingOverride = true
        } else {
            resolvedDirectory = defaultDirectory
            isUsingOverride = false
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedDirectory.path, isDirectory: &isDirectory)
        return LocalProviderSourceStatus(
            accountType: type,
            resolvedDirectory: resolvedDirectory,
            defaultDirectory: defaultDirectory,
            isUsingOverride: isUsingOverride,
            exists: exists,
            isDirectory: isDirectory.boolValue
        )
    }

    static func overrideDirectory(for type: AccountType, config: Config = ConfigManager.shared.load()) -> URL? {
        let accounts = Account.sortedForDisplay(config.accounts)
        guard let account = accounts.first(where: {
            $0.type == type && $0.isActive && ($0.trimmedLocalDataPath != nil)
        }) else {
            return nil
        }
        guard let overridePath = account.trimmedLocalDataPath else { return nil }
        return URL(fileURLWithPath: overridePath).standardizedFileURL
    }

    static func browseForDirectory(initialPath: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let initialPath, !initialPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: initialPath).deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func hintText(for type: AccountType) -> String {
        switch type {
        case .claudeCode:
            return "Expected Claude Code sessions directory."
        case .codex:
            return "Expected Codex sessions directory."
        case .gemini:
            return "Expected Gemini CLI session root."
        default:
            return ""
        }
    }
}
