import AppKit
import Foundation
import OSLog
import UserNotifications

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
        case "terminal-notifier": return .notification(title: "Claude Usage", body: rest)
        case "curl": return rest.isEmpty ? nil : .httpGet(url: rest)
        default: return nil
        }
    }
}

struct AutomationEngine {
    static func evaluate(rules: [AutomationRule], snapshot: UsageSnapshot) -> [AutomationRule] {
        rules.filter { rule in
            guard rule.enabled else { return false }
            switch rule.triggerType {
            case "cost_gt":   return snapshot.totalCostUSD > rule.threshold
            case "tokens_gt": return Double(snapshot.inputTokens + snapshot.outputTokens) > rule.threshold
            default: return false
            }
        }
    }

    static func fire(rule: AutomationRule, snapshot: UsageSnapshot) async {
        guard !rule.shellCommand.isEmpty else { return }
        guard let action = AutomationAction.parse(commandString: rule.shellCommand) else {
            ErrorLogger.shared.log("Rejected command for rule '\(rule.name)': parse failed or metacharacter detected")
            return
        }
        let env: [String: String] = [
            "CLAUDE_COST": String(format: "%.4f", snapshot.totalCostUSD),
            "CLAUDE_TOKENS": "\(snapshot.inputTokens + snapshot.outputTokens)",
            "CLAUDE_ACCOUNT": snapshot.accountId.uuidString,
        ].filter { rule.allowedEnvKeys.contains($0.key) }
        switch action {
        case .osascript(let script):
            await runProcess(execPath: "/usr/bin/osascript", args: ["-e", script], env: env, ruleName: rule.name)
        case .openURL(let url):
            if let u = URL(string: url) { await MainActor.run { NSWorkspace.shared.open(u) } }
        case .say(let text):
            await runProcess(execPath: "/usr/bin/say", args: [text], env: env, ruleName: rule.name)
        case .afplay(let path):
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard path.hasPrefix(home) else {
                ErrorLogger.shared.log("afplay path '\(path)' is outside home directory")
                return
            }
            await runProcess(execPath: "/usr/bin/afplay", args: [path], env: env, ruleName: rule.name)
        case .notification(let title, let body):
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(req)
        case .httpGet(let url):
            await runProcess(execPath: "/usr/bin/curl", args: [url], env: env, ruleName: rule.name)
        }
    }

    private static func runProcess(execPath: String, args: [String], env: [String: String], ruleName: String) async {
        let execURL = URL(fileURLWithPath: execPath)
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else {
            ErrorLogger.shared.log("Executable not found: \(execPath)")
            return
        }
        let process = Process()
        process.executableURL = execURL
        process.arguments = args
        process.environment = env
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do {
            try process.run(); process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("Rule '\(ruleName, privacy: .public)' exit \(process.terminationStatus): \(out, privacy: .public)")
        } catch {
            ErrorLogger.shared.log("Rule '\(ruleName)' launch failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func testRun(rule: AutomationRule) async -> String {
        guard !rule.shellCommand.isEmpty else { return "No command" }
        guard let action = AutomationAction.parse(commandString: rule.shellCommand) else {
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
        process.executableURL = execURL; process.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do {
            try process.run(); process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return out + (err.isEmpty ? "" : "\nSTDERR: " + err)
        } catch { return error.localizedDescription }
    }

    static func validateCommand(_ command: String) -> String? {
        AutomationAction.parse(commandString: command) == nil ? "Command not in allowlist or contains forbidden characters" : nil
    }
}
