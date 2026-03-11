import XCTest
@testable import SageBar

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

    func testScopedRuleOnlyMatchesConfiguredAccountIDs() {
        var scoped = rule(type: "cost_gt", threshold: 1.0)
        scoped.accountIDs = [accountId]
        let otherSnapshot = UsageSnapshot(
            accountId: UUID(),
            timestamp: Date(),
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 10,
            modelBreakdown: []
        )
        XCTAssertEqual(AutomationEngine.evaluate(rules: [scoped], snapshot: snap(cost: 10, tokens: 0)).count, 1)
        XCTAssertTrue(AutomationEngine.evaluate(rules: [scoped], snapshot: otherSnapshot).isEmpty)
    }

    func testGroupScopedRuleOnlyMatchesConfiguredGroupLabels() {
        let original = ConfigManager.shared.load()
        defer { _ = ConfigManager.shared.save(original) }

        var config = original
        config.accounts = [
            Account(
                name: "Client Local",
                type: .claudeCode,
                isActive: true,
                groupLabel: "Client A",
                order: 0
            )
        ]
        let scopedAccount = config.accounts[0]
        _ = ConfigManager.shared.save(config)

        var scoped = rule(type: "cost_gt", threshold: 1.0)
        scoped.groupLabels = ["Client A"]

        let matchingSnapshot = UsageSnapshot(
            accountId: scopedAccount.id,
            timestamp: Date(),
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 10,
            modelBreakdown: []
        )
        XCTAssertEqual(AutomationEngine.evaluate(rules: [scoped], snapshot: matchingSnapshot).count, 1)

        scoped.groupLabels = ["Client B"]
        XCTAssertTrue(AutomationEngine.evaluate(rules: [scoped], snapshot: matchingSnapshot).isEmpty)
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
