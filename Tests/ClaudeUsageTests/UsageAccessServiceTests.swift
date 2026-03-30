import XCTest
@testable import SageBar

final class UsageAccessServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "UsageAccessServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPreferredAccountUsesPersistedSelection() {
        let first = Account(name: "First", type: .claudeCode, isActive: true)
        let second = Account(name: "Second", type: .anthropicAPI, isActive: true, isPinned: true)
        var config = Config.default
        config.accounts = [first, second]

        defaults.set(second.id.uuidString, forKey: AppConstants.selectedAccountDefaultsKey)
        let preferred = UsageAccessService.preferredAccount(config: config, userDefaults: defaults)

        XCTAssertEqual(preferred?.id, second.id)
    }

    func testResolveAccountMatchesDisplayNameAndUUID() {
        let account = Account(name: "Agency", type: .claudeCode, isActive: true, groupLabel: "Client X")
        var config = Config.default
        config.accounts = [account]

        XCTAssertEqual(
            UsageAccessService.resolveAccount(identifierOrName: account.id.uuidString, config: config, userDefaults: defaults)?.id,
            account.id
        )
        XCTAssertEqual(
            UsageAccessService.resolveAccount(identifierOrName: "Agency • Client X", config: config, userDefaults: defaults)?.id,
            account.id
        )
    }

    func testAppleScriptBridgeCurrentUsageDefaultsToSelectedAccount() {
        let first = Account(name: "One", type: .claudeCode, isActive: true)
        let second = Account(name: "Two", type: .anthropicAPI, isActive: true, groupLabel: "Client B")
        var config = Config.default
        config.accounts = [first, second]
        defaults.set(second.id.uuidString, forKey: AppConstants.selectedAccountDefaultsKey)

        let usage = AppleScriptUsageBridge.getCurrentUsage(
            accountIdentifierOrName: nil,
            config: config,
            userDefaults: defaults
        )

        XCTAssertEqual(usage?["accountName"] as? String, "Two • Client B")
    }

    func testAppleScriptBridgeUsageSummaryResolvesExplicitAccount() {
        let first = Account(name: "Solo", type: .claudeCode, isActive: true)
        let second = Account(name: "Studio", type: .claudeAI, isActive: true, groupLabel: "Client Y")
        var config = Config.default
        config.accounts = [first, second]

        let summary = AppleScriptUsageBridge.getUsageSummary(
            accountIdentifierOrName: "Studio • Client Y",
            config: config,
            userDefaults: defaults
        )

        XCTAssertTrue(summary.contains("Account: Studio • Client Y"))
        XCTAssertTrue(summary.contains("Provider: Claude AI"))
    }

    func testDiagnosticsSnapshotJSONIncludesAccountAndTotals() async {
        let account = Account(name: "Telemetry", type: .codex, isActive: true, groupLabel: "Ops")
        var config = Config.default
        config.accounts = [account]

        let payload = await UsageAccessService.diagnosticsSnapshotJSON(config: config, maxErrorLines: 5)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let totals = object["totals"] as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else {
            XCTFail("expected diagnostics payload to be valid JSON")
            return
        }

        XCTAssertEqual(totals["accountCount"] as? Int, 1)
        XCTAssertEqual(totals["activeAccountCount"] as? Int, 1)
        XCTAssertEqual(accounts.first?["name"] as? String, "Telemetry")
        XCTAssertEqual(accounts.first?["providerType"] as? String, AccountType.codex.rawValue)
    }

    func testAppleScriptBridgeDiagnosticsSnapshotReturnsJSON() {
        let account = Account(name: "Scripting", type: .claudeCode, isActive: true)
        var config = Config.default
        config.accounts = [account]

        let payload = AppleScriptUsageBridge.getDiagnosticsSnapshot(config: config, maxErrorLines: 3)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("expected diagnostics payload to be valid JSON")
            return
        }

        XCTAssertNotNil(object["generatedAt"])
        XCTAssertNotNil(object["polling"])
        XCTAssertNotNil(object["recentErrors"])
    }
}
