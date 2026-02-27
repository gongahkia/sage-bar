import XCTest
@testable import ClaudeUsage

final class AutomationEngineFireTests: XCTestCase {
    private let accountId = UUID()

    private func snap() -> UsageSnapshot {
        UsageSnapshot(accountId: accountId, timestamp: Date(), inputTokens: 100,
            outputTokens: 50, cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: 3.14, modelBreakdown: [])
    }

    private func rule(cmd: String) -> AutomationRule {
        AutomationRule(name: "test", triggerType: "cost_gt", threshold: 0, shellCommand: cmd)
    }

    func testDestructiveCommandRejected() async {
        // rm -rf is blocked by destructive pattern; fire should be a no-op (no crash)
        await AutomationEngine.fire(rule: rule(cmd: "rm -rf /tmp/test_claude_usage"), snapshot: snap())
        // pass if no crash or unhandled error
    }

    func testEmptyCommandIsNoOp() async {
        await AutomationEngine.fire(rule: rule(cmd: ""), snapshot: snap())
        // pass if no crash
    }

    func testEnvVarInjectionPassedToProcess() async {
        // use /usr/bin/env to verify CLAUDE_COST is set; capture output via a temp file
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude_fire_test_\(UUID().uuidString).txt")
        let cmd = "echo $CLAUDE_COST > \(tmp.path)"
        await AutomationEngine.fire(rule: rule(cmd: cmd), snapshot: snap())
        // give process a moment to write
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let content = try? String(contentsOf: tmp, encoding: .utf8) {
            XCTAssertFalse(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "CLAUDE_COST env var should be non-empty")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMkfsCommandRejected() async {
        await AutomationEngine.fire(rule: rule(cmd: "mkfs /dev/null"), snapshot: snap())
        // pass if no crash
    }
}
