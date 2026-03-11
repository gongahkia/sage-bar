import XCTest
@testable import SageBar

final class SubConfigsTests: XCTestCase {
    // MARK: - ProviderPollingConfig.interval(for:)

    func testIntervalForEachType() {
        let cfg = ProviderPollingConfig.default
        XCTAssertEqual(cfg.interval(for: .claudeCode), 300)
        XCTAssertEqual(cfg.interval(for: .codex), 300)
        XCTAssertEqual(cfg.interval(for: .gemini), 300)
        XCTAssertEqual(cfg.interval(for: .anthropicAPI), 300)
        XCTAssertEqual(cfg.interval(for: .openAIOrg), 900)
        XCTAssertEqual(cfg.interval(for: .windsurfEnterprise), 600)
        XCTAssertEqual(cfg.interval(for: .githubCopilot), 3600)
        XCTAssertEqual(cfg.interval(for: .claudeAI), 300)
    }

    // MARK: - ProviderPollingConfig.setInterval

    func testSetIntervalMutatesCorrectField() {
        var cfg = ProviderPollingConfig.default
        cfg.setInterval(120, for: .openAIOrg)
        XCTAssertEqual(cfg.openAIOrg, 120)
        XCTAssertEqual(cfg.claudeCode, 300, "other fields unchanged")
    }

    func testSetIntervalAllTypes() {
        var cfg = ProviderPollingConfig.default
        for t in AccountType.allCases {
            cfg.setInterval(99, for: t)
            XCTAssertEqual(cfg.interval(for: t), 99, "\(t.rawValue)")
        }
    }

    // MARK: - ProviderPollingConfig defaults >= 60

    func testDefaultIntervalsAtLeast60() {
        let cfg = ProviderPollingConfig.default
        for t in AccountType.allCases {
            XCTAssertGreaterThanOrEqual(cfg.interval(for: t), 60,
                "\(t.rawValue) default interval must be >= 60s")
        }
    }

    // MARK: - Config.default validity

    func testConfigDefaultCreatesValidConfig() {
        let cfg = Config.default
        XCTAssertEqual(cfg.schemaVersion, 5)
        XCTAssertEqual(cfg.accounts.count, 1)
        XCTAssertEqual(cfg.accounts.first?.type, .claudeCode)
        XCTAssertEqual(cfg.accounts.first?.isActive, true)
        XCTAssertGreaterThan(cfg.pollIntervalSeconds, 0)
        XCTAssertEqual(cfg.providerPolling, .default)
        XCTAssertEqual(cfg.automations.count, 0)
        XCTAssertTrue(cfg.claudeAI.notifyOnLowMessages)
        XCTAssertEqual(cfg.claudeAI.lowMessagesThreshold, 10)
    }

    // MARK: - Config decoding missing providerPolling falls back to default

    func testDecodingMissingProviderPollingFallsBackToDefault() throws {
        // build a full config JSON without providerPolling key
        let defaultCfg = Config.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(defaultCfg)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "providerPolling")
        data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Config.self, from: data)
        XCTAssertEqual(decoded.providerPolling, ProviderPollingConfig.default,
            "missing providerPolling must fall back to default")
    }

    // MARK: - ProviderPollingConfig Codable round-trip

    func testProviderPollingCodableRoundTrip() throws {
        let original = ProviderPollingConfig(
            claudeCode: 100, codex: 200, gemini: 300,
            anthropicAPI: 400, openAIOrg: 500,
            windsurfEnterprise: 600, githubCopilot: 700, claudeAI: 800
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderPollingConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testClaudeAIConfigDefaultsWhenKeysMissing() throws {
        let config = try JSONDecoder().decode(ClaudeAIConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(config.notifyOnLowMessages)
        XCTAssertEqual(config.lowMessagesThreshold, 10)
    }

    func testLegacyAutomationRuleDecodeDefaultsToShellAction() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy Rule",
          "triggerType": "cost_gt",
          "threshold": 5,
          "shellCommand": "say hi",
          "enabled": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rule = try decoder.decode(AutomationRule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.id, id)
        XCTAssertEqual(rule.actionKind, "shell")
        XCTAssertEqual(rule.actionPayload, "say hi")
        XCTAssertEqual(rule.accountIDs, [])
        XCTAssertEqual(rule.groupLabels, [])
    }
}
