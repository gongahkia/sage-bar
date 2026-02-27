import Foundation
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "Automations")

struct AutomationEngine {
    static let allowedCommands: Set<String> = [
        "osascript", "open", "say", "curl", "afplay", "terminal-notifier"
    ]

    private static let injectionPatterns: [String] = ["$(", "`", "&&", "||", ";", "|", ">", "<"]

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
        if let reason = rejectionReason(rule.shellCommand) {
            ErrorLogger.shared.log("Rejected command for rule '\(rule.name)': \(reason)")
            return
        }
        guard let (execURL, args) = resolvedCommand(rule.shellCommand) else { return }
        let allowedEnv: [String: String] = [
            "CLAUDE_COST": String(format: "%.4f", snapshot.totalCostUSD),
            "CLAUDE_TOKENS": "\(snapshot.inputTokens + snapshot.outputTokens)",
            "CLAUDE_ACCOUNT": snapshot.accountId.uuidString,
        ].filter { rule.allowedEnvKeys.contains($0.key) }
        let process = Process()
        process.executableURL = execURL
        process.arguments = args
        process.environment = allowedEnv
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("Rule '\(rule.name, privacy: .public)' exit \(process.terminationStatus): \(out, privacy: .public)")
        } catch {
            ErrorLogger.shared.log("Rule '\(rule.name)' launch failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func testRun(rule: AutomationRule) async -> String {
        guard !rule.shellCommand.isEmpty else { return "No command" }
        if let reason = rejectionReason(rule.shellCommand) { return "Rejected: \(reason)" }
        guard let (execURL, args) = resolvedCommand(rule.shellCommand) else { return "Invalid executable" }
        let process = Process()
        process.executableURL = execURL
        process.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do {
            try process.run(); process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return out + (err.isEmpty ? "" : "\nSTDERR: " + err)
        } catch { return error.localizedDescription }
    }

    /// Returns nil if valid; returns rejection reason string otherwise.
    static func rejectionReason(_ command: String) -> String? {
        for pat in injectionPatterns {
            if command.contains(pat) { return "injection character '\(pat)'" }
        }
        let tokens = command.split(separator: " ", maxSplits: 1)
        guard let firstToken = tokens.first else { return "empty command" }
        let binaryName = URL(fileURLWithPath: String(firstToken)).lastPathComponent
        guard allowedCommands.contains(binaryName) else {
            return "'\(binaryName)' not in allowlist"
        }
        return nil
    }

    /// Returns (executableURL, remainingArgs) or nil if executable not found.
    static func resolvedCommand(_ command: String) -> (URL, [String])? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        let execPath: String
        if first.contains("/") {
            execPath = first
        } else {
            // resolve via PATH
            execPath = resolveInPath(first) ?? "/usr/bin/\(first)"
        }
        let execURL = URL(fileURLWithPath: execPath)
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else { return nil }
        return (execURL, parts.dropFirst().map { $0 })
    }

    static func validateShellCommand(_ command: String) -> String? {
        // returns nil if valid, error message if invalid
        if let reason = rejectionReason(command) { return reason }
        if resolvedCommand(command) == nil { return "Executable not found or not executable" }
        return nil
    }

    private static func resolveInPath(_ binary: String) -> String? {
        let paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? ["/usr/local/bin", "/usr/bin", "/bin"]
        return paths.map { "\($0)/\(binary)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
