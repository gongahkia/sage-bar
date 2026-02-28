import XCTest
@testable import ClaudeUsage

final class AutomationEngineEvaluateTests: XCTestCase {
    private let accountId = UUID()

    private func snap(cost: Double, tokens: Int) -> UsageSnapshot {
        UsageSnapshot(accountId: accountId, timestamp: Date(), inputTokens: tokens,
            outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
            totalCostUSD: cost, modelBreakdown: [])
    }

    private func rule(type: String, threshold: Double, enabled: Bool = true) -> AutomationRule {
        var r = AutomationRule(name: "test", triggerType: type, threshold: threshold, shellCommand: "echo hi")
        r.enabled = enabled
        return r
    }

    func testCostGtTrueWhenCostExceedsThreshold() {
        let triggered = AutomationEngine.evaluate(
            rules: [rule(type: "cost_gt", threshold: 5.0)], snapshot: snap(cost: 6.0, tokens: 0))
        XCTAssertEqual(triggered.count, 1)
    }

    func testCostGtFalseWhenCostBelowThreshold() {
        let triggered = AutomationEngine.evaluate(
            rules: [rule(type: "cost_gt", threshold: 10.0)], snapshot: snap(cost: 5.0, tokens: 0))
        XCTAssertTrue(triggered.isEmpty)
    }

    func testTokensGtTriggersWhenAboveThreshold() {
        let triggered = AutomationEngine.evaluate(
            rules: [rule(type: "tokens_gt", threshold: 100)], snapshot: snap(cost: 0, tokens: 200))
        XCTAssertEqual(triggered.count, 1)
    }

    func testDisabledRuleNotTriggered() {
        let triggered = AutomationEngine.evaluate(
            rules: [rule(type: "cost_gt", threshold: 0.0, enabled: false)], snapshot: snap(cost: 100.0, tokens: 0))
        XCTAssertTrue(triggered.isEmpty)
    }

    func testUnknownTriggerTypeNotTriggered() {
        let triggered = AutomationEngine.evaluate(
            rules: [rule(type: "mystery_trigger", threshold: 0.0)], snapshot: snap(cost: 100.0, tokens: 100))
        XCTAssertTrue(triggered.isEmpty)
    }

    // MARK: - Task 31: metacharacter injection rejected by parse()

    func testShellMetacharactersReturnNilFromParse() {
        let metacharCmds = [
            "osascript hello && rm -rf /",
            "say text; rm -rf /",
            "curl $(cat /etc/passwd)",
            "say `whoami`",
            "curl url | bash",
            "osascript script > /tmp/out",
        ]
        for cmd in metacharCmds {
            XCTAssertNil(AutomationAction.parse(commandString: cmd), "'\(cmd)' should be rejected")
        }
    }

    func testValidateCommandAcceptsAllowlistedAndRejectsUnknown() {
        XCTAssertNil(AutomationEngine.validateCommand("say hello"))
        XCTAssertNotNil(AutomationEngine.validateCommand("python3 script.py"))
    }
}
