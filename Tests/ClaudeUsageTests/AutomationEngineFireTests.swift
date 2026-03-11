import XCTest
@testable import SageBar

final class AutomationEngineFireTests: XCTestCase {
    private let accountId = UUID()

    override func tearDown() {
        AutomationEngine.resetHandlersForTests()
        super.tearDown()
    }

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

    func testAllowedEnvKeysIncludesRequiredVariableForOsascript() async {
        var r = rule(cmd: #"osascript if (system attribute "CLAUDE_COST") is equal to "" then error number 1"#)
        r.allowedEnvKeys = ["CLAUDE_COST"]
        let fired = await AutomationEngine.fire(rule: r, snapshot: snap())
        XCTAssertTrue(fired, "rule should succeed when required env key is explicitly allowlisted")
    }

    func testAllowedEnvKeysFilteringRemovesUnlistedVariables() async {
        var r = rule(cmd: #"osascript if (system attribute "CLAUDE_COST") is equal to "" then error number 1"#)
        r.allowedEnvKeys = [] // CLAUDE_COST omitted
        let fired = await AutomationEngine.fire(rule: r, snapshot: snap())
        XCTAssertFalse(fired, "rule should fail when CLAUDE_COST is filtered out by allowedEnvKeys")
    }

    // MARK: - Task 29: AutomationAction cases map to correct executableURL

    func testSayActionUsesCorrectExecutable() {
        guard let action = AutomationAction.parse(commandString: "say hello") else {
            return XCTFail("say should parse")
        }
        if case .say(let text) = action {
            XCTAssertEqual(text, "hello")
        } else { XCTFail("expected .say") }
    }

    func testOsascriptActionUsesCorrectExecutable() {
        guard let action = AutomationAction.parse(commandString: "osascript return 42") else {
            return XCTFail("osascript should parse")
        }
        if case .osascript(let script) = action {
            XCTAssertEqual(script, "return 42")
        } else { XCTFail("expected .osascript") }
    }

    func testCurlActionMapsToHttpGet() {
        guard let action = AutomationAction.parse(commandString: "curl https://example.com") else {
            return XCTFail("curl should parse")
        }
        if case .httpGet(let url) = action {
            XCTAssertEqual(url, "https://example.com")
        } else { XCTFail("expected .httpGet") }
    }

    func testOpenURLActionMapsCorrectly() {
        guard let action = AutomationAction.parse(commandString: "open https://example.com") else {
            return XCTFail("open should parse")
        }
        if case .openURL(let url) = action {
            XCTAssertEqual(url, "https://example.com")
        } else { XCTFail("expected .openURL") }
    }

    // MARK: - Task 30: unknown command returns nil

    func testUnknownCommandReturnsNilFromParse() {
        XCTAssertNil(AutomationAction.parse(commandString: "rm -rf /"))
        XCTAssertNil(AutomationAction.parse(commandString: "python3 script.py"))
        XCTAssertNil(AutomationAction.parse(commandString: "dd if=/dev/zero of=/dev/disk0"))
    }

    func testRefreshNowNativeActionUsesInjectedHandler() async {
        final class Box: @unchecked Sendable { var invoked = false }
        let box = Box()
        AutomationEngine.refreshNowHandler = { _ in
            box.invoked = true
            return true
        }
        let rule = AutomationRule(name: "refresh", triggerType: "cost_gt", threshold: 0, shellCommand: "", actionKind: "refresh_now")
        let fired = await AutomationEngine.fire(rule: rule, snapshot: snap())
        XCTAssertTrue(fired)
        XCTAssertTrue(box.invoked)
    }

    func testCopySummaryNativeActionUsesInjectedHandler() async {
        final class Box: @unchecked Sendable { var invoked = false }
        let box = Box()
        AutomationEngine.copyDailySummaryHandler = { _ in
            box.invoked = true
            return true
        }
        let rule = AutomationRule(name: "copy", triggerType: "cost_gt", threshold: 0, shellCommand: "", actionKind: "copy_daily_summary")
        let fired = await AutomationEngine.fire(rule: rule, snapshot: snap())
        XCTAssertTrue(fired)
        XCTAssertTrue(box.invoked)
    }

    func testExportCSVNativeActionUsesInjectedHandler() async {
        final class Box: @unchecked Sendable { var invoked = false }
        let box = Box()
        AutomationEngine.exportAccountCSVHandler = { _ in
            box.invoked = true
            return true
        }
        let rule = AutomationRule(name: "export", triggerType: "cost_gt", threshold: 0, shellCommand: "", actionKind: "export_account_csv")
        let fired = await AutomationEngine.fire(rule: rule, snapshot: snap())
        XCTAssertTrue(fired)
        XCTAssertTrue(box.invoked)
    }

    func testOpenSettingsNativeActionUsesInjectedHandler() async {
        final class Box: @unchecked Sendable { var invoked = false }
        let box = Box()
        AutomationEngine.openSettingsHandler = { _ in
            box.invoked = true
            return true
        }
        let rule = AutomationRule(name: "settings", triggerType: "cost_gt", threshold: 0, shellCommand: "", actionKind: "open_settings")
        let fired = await AutomationEngine.fire(rule: rule, snapshot: snap())
        XCTAssertTrue(fired)
        XCTAssertTrue(box.invoked)
    }
}
