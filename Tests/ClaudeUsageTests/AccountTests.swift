import XCTest
@testable import SageBar

final class AccountTests: XCTestCase {
    // MARK: - AccountType.displayName

    func testDisplayNameClaudeCode() { XCTAssertEqual(AccountType.claudeCode.displayName, "Claude Code") }
    func testDisplayNameCodex() { XCTAssertEqual(AccountType.codex.displayName, "Codex") }
    func testDisplayNameGemini() { XCTAssertEqual(AccountType.gemini.displayName, "Gemini") }
    func testDisplayNameAnthropicAPI() { XCTAssertEqual(AccountType.anthropicAPI.displayName, "Anthropic API") }
    func testDisplayNameOpenAIOrg() { XCTAssertEqual(AccountType.openAIOrg.displayName, "OpenAI Org") }
    func testDisplayNameWindsurfEnterprise() { XCTAssertEqual(AccountType.windsurfEnterprise.displayName, "Windsurf Enterprise") }
    func testDisplayNameGitHubCopilot() { XCTAssertEqual(AccountType.githubCopilot.displayName, "GitHub Copilot") }
    func testDisplayNameClaudeAI() { XCTAssertEqual(AccountType.claudeAI.displayName, "Claude AI") }

    // MARK: - providerStrategy

    func testCoreProviders() {
        let core: [AccountType] = [.claudeCode, .codex, .gemini]
        for t in core {
            XCTAssertEqual(t.providerStrategy, .core, "\(t.rawValue) should be core")
            XCTAssertTrue(t.isCoreProvider)
        }
    }

    func testExperimentalProviders() {
        let experimental: [AccountType] = [.anthropicAPI, .openAIOrg, .windsurfEnterprise, .githubCopilot, .claudeAI]
        for t in experimental {
            XCTAssertEqual(t.providerStrategy, .experimental, "\(t.rawValue) should be experimental")
            XCTAssertFalse(t.isCoreProvider)
        }
    }

    // MARK: - ProviderCapabilities credential modes

    func testCredentialModeNone() {
        for t: AccountType in [.claudeCode, .codex, .gemini] {
            XCTAssertEqual(t.capabilities.credentialMode, .none, "\(t.rawValue)")
        }
    }

    func testCredentialModeAnthropicAPIKey() {
        XCTAssertEqual(AccountType.anthropicAPI.capabilities.credentialMode, .anthropicAPIKey)
    }

    func testCredentialModeOpenAIAdminKey() {
        XCTAssertEqual(AccountType.openAIOrg.capabilities.credentialMode, .openAIAdminKey)
    }

    func testCredentialModeWindsurfServiceKey() {
        XCTAssertEqual(AccountType.windsurfEnterprise.capabilities.credentialMode, .windsurfServiceKey)
    }

    func testCredentialModeGitHubTokenAndOrg() {
        XCTAssertEqual(AccountType.githubCopilot.capabilities.credentialMode, .githubTokenAndOrg)
    }

    func testCredentialModeClaudeAISessionToken() {
        XCTAssertEqual(AccountType.claudeAI.capabilities.credentialMode, .claudeAISessionToken)
    }

    func testAllProvidersSupportsConnectionTest() {
        for t in AccountType.allCases {
            XCTAssertTrue(t.capabilities.supportsConnectionTest, "\(t.rawValue)")
        }
    }

    // MARK: - Account init negative costLimitUSD

    func testNegativeCostLimitSetsNil() {
        let acct = Account(name: "Test", type: .claudeCode, costLimitUSD: -5.0)
        XCTAssertNil(acct.costLimitUSD, "negative costLimitUSD must be set to nil")
    }

    func testZeroCostLimitSetsNil() {
        let acct = Account(name: "Test", type: .claudeCode, costLimitUSD: 0.0)
        XCTAssertNil(acct.costLimitUSD, "zero costLimitUSD must be set to nil")
    }

    func testPositiveCostLimitPreserved() {
        let acct = Account(name: "Test", type: .claudeCode, costLimitUSD: 10.0)
        XCTAssertEqual(acct.costLimitUSD, 10.0)
    }

    func testNilCostLimitStaysNil() {
        let acct = Account(name: "Test", type: .claudeCode)
        XCTAssertNil(acct.costLimitUSD)
    }

    // MARK: - Account Codable round-trip

    func testAccountCodingRoundTrip() throws {
        let original = Account(name: "RoundTrip", type: .anthropicAPI, isActive: false, order: 3, costLimitUSD: 42.5)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, "RoundTrip")
        XCTAssertEqual(decoded.type, .anthropicAPI)
        XCTAssertEqual(decoded.isActive, false)
        XCTAssertEqual(decoded.order, 3)
        XCTAssertEqual(decoded.costLimitUSD, 42.5)
    }

    func testAccountDecodingMissingOrderDefaultsToZero() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"NoOrder","type":"claudeCode","isActive":true,"createdAt":"2025-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let acct = try decoder.decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(acct.order, 0)
    }

    func testAccountDecodingMissingPinnedAndGroupDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"NoPin","type":"claudeCode","isActive":true,"createdAt":"2025-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let acct = try decoder.decode(Account.self, from: Data(json.utf8))
        XCTAssertFalse(acct.isPinned)
        XCTAssertNil(acct.groupLabel)
    }

    func testAccountInitTrimsGroupLabel() {
        let acct = Account(name: "Grouped", type: .claudeCode, groupLabel: "  Client A  ")
        XCTAssertEqual(acct.groupLabel, "Client A")
    }

    func testSortedForDisplayPrefersPinnedThenOrderThenCreatedAt() {
        var oldestPinned = Account(name: "Pinned Old", type: .claudeCode, isPinned: true, order: 2)
        oldestPinned.createdAt = Date(timeIntervalSince1970: 10)
        var newestPinned = Account(name: "Pinned New", type: .claudeCode, isPinned: true, order: 2)
        newestPinned.createdAt = Date(timeIntervalSince1970: 20)
        var unpinnedLowOrder = Account(name: "Unpinned First", type: .claudeCode, isPinned: false, order: 1)
        unpinnedLowOrder.createdAt = Date(timeIntervalSince1970: 5)

        let sorted = Account.sortedForDisplay([newestPinned, unpinnedLowOrder, oldestPinned])
        XCTAssertEqual(sorted.map(\.name), ["Pinned Old", "Pinned New", "Unpinned First"])
    }

    func testDisplayLabelIncludesGroupWhenPresent() {
        let acct = Account(name: "Consulting", type: .anthropicAPI, groupLabel: "Client X")
        XCTAssertEqual(acct.displayLabel(among: [acct]), "Consulting • Client X")
    }

    func testLocalProvidersSupportWorkstreamAttribution() {
        XCTAssertTrue(AccountType.claudeCode.supportsWorkstreamAttribution)
        XCTAssertTrue(AccountType.codex.supportsWorkstreamAttribution)
        XCTAssertTrue(AccountType.gemini.supportsWorkstreamAttribution)
        XCTAssertFalse(AccountType.anthropicAPI.supportsWorkstreamAttribution)
    }

    func testResolvedWorkstreamLabelPrefersConfiguredRule() {
        let rule = WorkstreamRule(name: "Client A", pathPattern: "client-a")
        let account = Account(name: "Local", type: .claudeCode, workstreamRules: [rule])
        let label = account.resolvedWorkstreamLabel(for: "/Users/test/.claude/projects/client-a/session.jsonl")
        XCTAssertEqual(label, "Client A")
    }

    func testResolvedWorkstreamLabelFallsBackToPathInference() {
        let account = Account(name: "Local", type: .claudeCode)
        let label = account.resolvedWorkstreamLabel(for: "/Users/test/.claude/projects/agency-site/session.jsonl")
        XCTAssertEqual(label, "agency site")
    }

    // MARK: - AccountType Codable round-trip

    func testAccountTypeCodingRoundTrip() throws {
        for t in AccountType.allCases {
            let data = try JSONEncoder().encode(t)
            let decoded = try JSONDecoder().decode(AccountType.self, from: data)
            XCTAssertEqual(decoded, t, "\(t.rawValue) round-trip failed")
        }
    }
}
