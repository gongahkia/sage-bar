import Foundation
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "Automations")
private let destructivePattern = try! NSRegularExpression(pattern: #"\brm\s+-rf\b|\bformat\b|\bmkfs\b"#)

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
        guard !isDestructive(rule.shellCommand) else {
            log.warning("Rejected destructive command for rule '\(rule.name, privacy: .public)'")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", rule.shellCommand]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CLAUDE_COST": String(format: "%.4f", snapshot.totalCostUSD),
            "CLAUDE_TOKENS": "\(snapshot.inputTokens + snapshot.outputTokens)",
            "CLAUDE_ACCOUNT": snapshot.accountId.uuidString,
        ]) { _, new in new }
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("Rule '\(rule.name, privacy: .public)' exit \(process.terminationStatus): \(out, privacy: .public)")
        } catch {
            log.error("Rule '\(rule.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// test run: does not update lastFiredAt
    @discardableResult
    static func testRun(rule: AutomationRule) async -> String {
        guard !rule.shellCommand.isEmpty else { return "No command" }
        guard !isDestructive(rule.shellCommand) else { return "⚠ Rejected: destructive pattern" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", rule.shellCommand]
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do {
            try process.run(); process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return out + (err.isEmpty ? "" : "\nSTDERR: " + err)
        } catch { return error.localizedDescription }
    }

    private static func isDestructive(_ cmd: String) -> Bool {
        let range = NSRange(cmd.startIndex..., in: cmd)
        return destructivePattern.firstMatch(in: cmd, range: range) != nil
    }
}
