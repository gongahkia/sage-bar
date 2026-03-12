import XCTest
@testable import SageBar

final class ProductStateResolverTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "product-state-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPopoverGlobalStateShowsNoActiveAccounts() {
        let setupStore = makeSetupStore()
        var config = Config.default
        config.accounts = []
        let card = ProductStateResolver.popoverGlobalState(config: config, setupExperience: setupStore)

        XCTAssertEqual(card?.title, "No active accounts")
        XCTAssertEqual(card?.primaryAction.title, "Run Setup Wizard")
    }

    func testPopoverGlobalStateShowsDemoPreviewWhenDemoModeEnabled() {
        let setupStore = makeSetupStore()
        setupStore.enableDemoMode()
        var config = Config.default
        config.accounts = []

        let card = ProductStateResolver.popoverGlobalState(config: config, setupExperience: setupStore)

        XCTAssertEqual(card?.title, "Demo mode preview")
        XCTAssertEqual(card?.secondaryAction?.kind, .disableDemoMode)
    }

    func testAccountStateShowsMissingLocalSource() {
        let account = Account(
            name: "Claude Code",
            type: .claudeCode,
            localDataPath: "/tmp/definitely-missing-\(UUID().uuidString)"
        )

        let card = ProductStateResolver.accountState(
            for: account,
            latestSnapshot: nil,
            lastSuccess: nil,
            claudeAIStatus: nil,
            fetchErrorMessage: nil,
            fetchErrorUpdatedAt: nil,
            pollIntervalSeconds: 300
        )

        XCTAssertEqual(card?.title, "Local source missing")
        XCTAssertEqual(card?.primaryAction.kind, .openAccountsSettings)
    }

    func testAccountStateShowsCredentialFailure() {
        let account = Account(name: "OpenAI", type: .openAIOrg)

        let card = ProductStateResolver.accountState(
            for: account,
            latestSnapshot: nil,
            lastSuccess: nil,
            claudeAIStatus: nil,
            fetchErrorMessage: "Invalid OpenAI admin key or insufficient org permissions",
            fetchErrorUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pollIntervalSeconds: 300
        )

        XCTAssertEqual(card?.title, "Connection needs attention")
        XCTAssertEqual(card?.primaryAction.kind, .reconnectSettings)
    }

    func testAccountStateShowsClaudeAIReauthRequirement() {
        let account = Account(name: "Claude AI", type: .claudeAI)
        let status = ClaudeAIStatus(
            accountId: account.id,
            messagesRemaining: 0,
            messagesUsed: 100,
            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            sessionHealth: .reauthRequired
        )

        let card = ProductStateResolver.accountState(
            for: account,
            latestSnapshot: nil,
            lastSuccess: nil,
            claudeAIStatus: status,
            fetchErrorMessage: nil,
            fetchErrorUpdatedAt: status.lastUpdated,
            pollIntervalSeconds: 300
        )

        XCTAssertEqual(card?.title, "Claude AI needs re-authentication")
        XCTAssertEqual(card?.primaryAction.kind, .reconnectSettings)
    }

    func testAccountStateShowsStaleData() {
        let account = Account(name: "Anthropic API", type: .anthropicAPI)
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        let snapshot = UsageSnapshot(
            accountId: account.id,
            timestamp: now.addingTimeInterval(-900),
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 1.0,
            modelBreakdown: []
        )

        let card = ProductStateResolver.accountState(
            for: account,
            latestSnapshot: snapshot,
            lastSuccess: snapshot.timestamp,
            claudeAIStatus: nil,
            fetchErrorMessage: nil,
            fetchErrorUpdatedAt: nil,
            pollIntervalSeconds: 300,
            now: now
        )

        XCTAssertEqual(card?.title, "Using stale data")
        XCTAssertEqual(card?.primaryAction.kind, .refreshNow)
    }

    func testReportingRangeStateShowsNoDataCard() {
        let account = Account(name: "No Data", type: .anthropicAPI)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_086_400)
        )

        let card = ProductStateResolver.reportingRangeState(accounts: [account], interval: interval)

        XCTAssertEqual(card?.title, "No data in this date range")
        XCTAssertEqual(card?.secondaryAction?.kind, .exportAllTime)
    }

    private func makeSetupStore() -> SetupExperienceStore {
        SetupExperienceStore(
            defaults: defaults,
            stateKey: "setupExperienceState",
            currentVersion: 1,
            accountValidator: { _ in false }
        )
    }
}
