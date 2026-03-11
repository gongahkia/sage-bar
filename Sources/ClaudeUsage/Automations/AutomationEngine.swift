import AppKit
import Foundation
import OSLog
import UserNotifications
import Darwin

private let log = Logger(subsystem: "dev.claudeusage", category: "Automations")

// MARK: – AutomationAction

enum AutomationAction {
    case osascript(script: String)
    case openURL(url: String)
    case say(text: String)
    case afplay(path: String)
    case notification(title: String, body: String)
    case httpGet(url: String)

    private static let metacharacters = ["$(", "`", "&&", "||", ";", "|", ">", "<"]

    static func parse(commandString: String) -> AutomationAction? {
        guard !metacharacters.contains(where: { commandString.contains($0) }) else { return nil }
        let parts = commandString.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first else { return nil }
        let rest = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "osascript": return rest.isEmpty ? nil : .osascript(script: rest)
        case "open": return rest.isEmpty ? nil : .openURL(url: rest)
        case "say": return rest.isEmpty ? nil : .say(text: rest)
        case "afplay": return rest.isEmpty ? nil : .afplay(path: rest)
        case "terminal-notifier": return .notification(title: "Sage Bar", body: rest)
        case "curl":
            let args = rest.split(separator: " ").map(String.init)
            guard args.count == 1, let target = args.first else { return nil }
            guard !target.hasPrefix("-"), target.hasPrefix("http://") || target.hasPrefix("https://") else { return nil }
            return .httpGet(url: target)
        default: return nil
        }
    }
}

enum AutomationPresetAction: String, CaseIterable {
    case shell = "shell"
    case refreshNow = "refresh_now"
    case copyDailySummary = "copy_daily_summary"
    case exportAccountCSV = "export_account_csv"
    case openSettings = "open_settings"

    var displayName: String {
        switch self {
        case .shell: return "Shell Command"
        case .refreshNow: return "Refresh Now"
        case .copyDailySummary: return "Copy Daily Summary"
        case .exportAccountCSV: return "Export Account CSV"
        case .openSettings: return "Open Settings"
        }
    }

    var isShell: Bool { self == .shell }
}

struct AutomationEngine {
    private static let processTimeoutSeconds: TimeInterval = 15
    static var refreshNowHandler: @Sendable (UsageSnapshot) async -> Bool = { _ in
        await MainActor.run {
            PollingService.shared.requestFollowUpRefresh()
            return true
        }
    }
    static var copyDailySummaryHandler: @Sendable (UsageSnapshot) async -> Bool = { snapshot in
        guard let account = resolvedAccount(for: snapshot.accountId) else { return false }
        let activeAccounts = Account.activeAccounts(in: ConfigManager.shared.load())
        return await MainActor.run {
            UsageReportingService.copySummaryToPasteboard(for: account, among: activeAccounts)
        }
    }
    static var exportAccountCSVHandler: @Sendable (UsageSnapshot) async -> Bool = { snapshot in
        guard let account = resolvedAccount(for: snapshot.accountId) else { return false }
        do {
            _ = try await MainActor.run {
                try UsageReportingService.exportCSV(for: account)
            }
            return true
        } catch {
            ErrorLogger.shared.log("Export account CSV automation failed: \(error.localizedDescription)")
            return false
        }
    }
    static var openSettingsHandler: @Sendable (UsageSnapshot) async -> Bool = { _ in
        await MainActor.run {
            SettingsWindowController.shared.showWindow()
            return true
        }
    }

    static func evaluate(rules: [AutomationRule], snapshot: UsageSnapshot) -> [AutomationRule] {
        rules.filter { rule in
            guard rule.enabled else { return false }
            if !rule.accountIDs.isEmpty && !rule.accountIDs.contains(snapshot.accountId) {
                return false
            }
            if !rule.groupLabels.isEmpty {
                guard let account = resolvedAccount(for: snapshot.accountId),
                      let groupLabel = account.trimmedGroupLabel else {
                    return false
                }
                let matchesGroup = rule.groupLabels.contains {
                    $0.caseInsensitiveCompare(groupLabel) == .orderedSame
                }
                guard matchesGroup else { return false }
            }
            switch rule.triggerType {
            case "cost_gt":
                return snapshot.totalCostUSD > rule.threshold
            case "tokens_gt":
                return Double(snapshot.inputTokens + snapshot.outputTokens) > rule.threshold
            default:
                return false
            }
        }
    }

    @discardableResult
    static func fire(rule: AutomationRule, snapshot: UsageSnapshot, cooldownSeconds: Int = 300) async -> Bool {
        if let lastFired = AutomationCooldownStore.shared.lastFiredAt(ruleID: rule.id) ?? rule.lastFiredAt {
            let elapsed = Date().timeIntervalSince(lastFired)
            if elapsed < TimeInterval(max(1, cooldownSeconds)) {
                ErrorLogger.shared.log("Rule '\(rule.name)' skipped: cooldown \(Int(elapsed))s/\(cooldownSeconds)s", level: "INFO")
                await recordHistory(
                    rule: rule,
                    snapshot: snapshot,
                    success: false,
                    dryRun: false,
                    message: "Skipped: cooldown active"
                )
                return false
            }
        }

        guard let actionKind = AutomationPresetAction(rawValue: rule.actionKind) else {
            ErrorLogger.shared.log("Unknown automation action '\(rule.actionKind)' for rule '\(rule.name)'")
            await recordHistory(
                rule: rule,
                snapshot: snapshot,
                success: false,
                dryRun: false,
                message: "Unknown action '\(rule.actionKind)'"
            )
            return false
        }

        let fired: Bool
        let message: String
        switch actionKind {
        case .shell:
            fired = await fireShell(rule: rule, snapshot: snapshot)
            message = fired ? "Shell command completed" : "Shell command failed"
        case .refreshNow:
            fired = await refreshNowHandler(snapshot)
            message = fired ? "Queued a follow-up refresh" : "Refresh action failed"
        case .copyDailySummary:
            fired = await copyDailySummaryHandler(snapshot)
            message = fired ? "Copied daily summary for triggering account" : "Copy daily summary failed"
        case .exportAccountCSV:
            fired = await exportAccountCSVHandler(snapshot)
            message = fired ? "Exported account CSV for triggering account" : "Export account CSV failed"
        case .openSettings:
            fired = await openSettingsHandler(snapshot)
            message = fired ? "Opened Settings" : "Open Settings failed"
        }
        await recordHistory(rule: rule, snapshot: snapshot, success: fired, dryRun: false, message: message)
        return fired
    }

    @discardableResult
    static func testRun(rule: AutomationRule) async -> String {
        guard let actionKind = AutomationPresetAction(rawValue: rule.actionKind) else {
            return "Unknown action"
        }
        switch actionKind {
        case .shell:
            let command = shellCommand(for: rule)
            guard !command.isEmpty else { return "No command" }
            guard let action = AutomationAction.parse(commandString: command) else {
                return "Rejected: parse failed or metacharacter detected"
            }
            let execPath: String
            let args: [String]
            switch action {
            case .osascript(let script): execPath = "/usr/bin/osascript"; args = ["-e", script]
            case .say(let text): execPath = "/usr/bin/say"; args = [text]
            case .afplay(let path): execPath = "/usr/bin/afplay"; args = [path]
            case .httpGet(let url): execPath = "/usr/bin/curl"; args = [url]
            case .openURL: return "openURL — handled via NSWorkspace"
            case .notification: return "notification — handled via UNUserNotificationCenter"
            }
            let execURL = URL(fileURLWithPath: execPath)
            guard FileManager.default.isExecutableFile(atPath: execURL.path) else { return "Executable not found" }
            let process = Process()
            process.executableURL = execURL
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
                process.waitUntilExit()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let output = out + (err.isEmpty ? "" : "\nSTDERR: " + err)
                await recordHistory(rule: rule, snapshot: nil, success: process.terminationStatus == 0, dryRun: true, message: output.isEmpty ? "Shell preview completed" : output)
                return output
            } catch {
                await recordHistory(rule: rule, snapshot: nil, success: false, dryRun: true, message: error.localizedDescription)
                return error.localizedDescription
            }
        case .refreshNow, .copyDailySummary, .exportAccountCSV, .openSettings:
            let preview = previewDescription(for: actionKind, rule: rule)
            await recordHistory(rule: rule, snapshot: nil, success: true, dryRun: true, message: preview)
            return preview
        }
    }

    static func validateCommand(_ command: String) -> String? {
        AutomationAction.parse(commandString: command) == nil ? "Command not in allowlist or contains forbidden characters" : nil
    }

    static func shellCommand(for rule: AutomationRule) -> String {
        let command = rule.shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            return command
        }
        return (rule.actionPayload ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resetHandlersForTests() {
        refreshNowHandler = { _ in
            await MainActor.run {
                PollingService.shared.requestFollowUpRefresh()
                return true
            }
        }
        copyDailySummaryHandler = { snapshot in
            guard let account = resolvedAccount(for: snapshot.accountId) else { return false }
            let activeAccounts = Account.activeAccounts(in: ConfigManager.shared.load())
            return await MainActor.run {
                UsageReportingService.copySummaryToPasteboard(for: account, among: activeAccounts)
            }
        }
        exportAccountCSVHandler = { snapshot in
            guard let account = resolvedAccount(for: snapshot.accountId) else { return false }
            do {
                _ = try await MainActor.run {
                    try UsageReportingService.exportCSV(for: account)
                }
                return true
            } catch {
                ErrorLogger.shared.log("Export account CSV automation failed: \(error.localizedDescription)")
                return false
            }
        }
        openSettingsHandler = { _ in
            await MainActor.run {
                SettingsWindowController.shared.showWindow()
                return true
            }
        }
    }

    private static let sensitiveEnvKeys = [
        "CLAUDE_COST", "CLAUDE_TOKENS", "CLAUDE_ACCOUNT",
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GITHUB_TOKEN",
        "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    ]

    private static func fireShell(rule: AutomationRule, snapshot: UsageSnapshot) async -> Bool {
        let command = shellCommand(for: rule)
        guard !command.isEmpty else { return false }
        guard let action = AutomationAction.parse(commandString: command) else {
            ErrorLogger.shared.log("Rejected command for rule '\(rule.name)': parse failed or metacharacter detected")
            return false
        }
        let injectedEnv: [String: String] = [
            "CLAUDE_COST": String(format: "%.4f", snapshot.totalCostUSD),
            "CLAUDE_TOKENS": "\(snapshot.inputTokens + snapshot.outputTokens)",
            "CLAUDE_ACCOUNT": snapshot.accountId.uuidString,
        ].filter { rule.allowedEnvKeys.contains($0.key) }
        switch action {
        case .osascript(let script):
            return await runProcess(execPath: "/usr/bin/osascript", args: ["-e", script], injectedEnv: injectedEnv, ruleName: rule.name)
        case .openURL(let url):
            guard let u = URL(string: url) else { return false }
            return await MainActor.run { NSWorkspace.shared.open(u) }
        case .say(let text):
            return await runProcess(execPath: "/usr/bin/say", args: [text], injectedEnv: injectedEnv, ruleName: rule.name)
        case .afplay(let path):
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard path.hasPrefix(home) else {
                ErrorLogger.shared.log("afplay path '\(path)' is outside home directory")
                return false
            }
            return await runProcess(execPath: "/usr/bin/afplay", args: [path], injectedEnv: injectedEnv, ruleName: rule.name)
        case .notification(let title, let body):
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            guard let center = userNotificationCenterIfAvailable() else { return true }
            do {
                try await center.add(req)
                return true
            } catch {
                ErrorLogger.shared.log("Notification action failed for rule '\(rule.name)': \(error.localizedDescription)")
                return false
            }
        case .httpGet(let url):
            return await runProcess(execPath: "/usr/bin/curl", args: [url], injectedEnv: injectedEnv, ruleName: rule.name)
        }
    }

    private static func resolvedAccount(for accountID: UUID) -> Account? {
        ConfigManager.shared.load().accounts.first(where: { $0.id == accountID })
    }

    private static func previewDescription(for actionKind: AutomationPresetAction, rule: AutomationRule) -> String {
        switch actionKind {
        case .shell:
            return "Would run shell command"
        case .refreshNow:
            return "Would queue an immediate refresh for the triggering account"
        case .copyDailySummary:
            return "Would copy the triggering account's daily summary to the pasteboard"
        case .exportAccountCSV:
            return "Would export the triggering account's CSV report to the Desktop"
        case .openSettings:
            return "Would open Sage Bar Settings"
        }
    }

    private static func recordHistory(
        rule: AutomationRule,
        snapshot: UsageSnapshot?,
        success: Bool,
        dryRun: Bool,
        message: String
    ) async {
        let account = snapshot.flatMap { resolvedAccount(for: $0.accountId) }
        let accountName: String?
        if let account {
            let fallbackAccounts = [account]
            accountName = account.trimmedName.isEmpty
                ? account.displayLabel(among: fallbackAccounts)
                : account.trimmedName
        } else {
            accountName = nil
        }
        let record = AutomationRunRecord(
            ruleID: rule.id,
            ruleName: rule.name,
            accountID: snapshot?.accountId,
            accountName: accountName,
            success: success,
            dryRun: dryRun,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (success ? "Completed" : "Failed") : message
        )
        await AutomationRunHistoryStore.shared.append(record)
    }

    private static func runProcess(execPath: String, args: [String], injectedEnv: [String: String], ruleName: String) async -> Bool {
        let execURL = URL(fileURLWithPath: execPath)
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else {
            ErrorLogger.shared.log("Executable not found: \(execPath)")
            return false
        }
        let process = Process()
        process.executableURL = execURL
        process.arguments = args
        process.environment = processEnvironment(injectedEnv: injectedEnv)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(processTimeoutSeconds)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(nanoseconds: 100_000_000)
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
                ErrorLogger.shared.log("Rule '\(ruleName)' timed out after \(Int(processTimeoutSeconds))s and was terminated")
                return false
            }
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("Rule '\(ruleName, privacy: .public)' exit \(process.terminationStatus): \(out, privacy: .public)")
            return process.terminationStatus == 0
        } catch {
            ErrorLogger.shared.log("Rule '\(ruleName)' launch failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func processEnvironment(injectedEnv: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in sensitiveEnvKeys {
            env.removeValue(forKey: key)
        }
        for (key, value) in injectedEnv {
            env[key] = value
        }
        return env
    }

    private static func userNotificationCenterIfAvailable() -> UNUserNotificationCenter? {
        let env = ProcessInfo.processInfo.environment
        let runningTests = env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || ProcessInfo.processInfo.processName == "xctest"
            || NSClassFromString("XCTestCase") != nil
        guard !runningTests else {
            return nil
        }
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app",
              let bundleID = Bundle.main.bundleIdentifier,
              !bundleID.isEmpty else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }
}
