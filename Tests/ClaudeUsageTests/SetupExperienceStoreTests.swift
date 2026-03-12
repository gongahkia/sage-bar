import XCTest
@testable import SageBar

final class SetupExperienceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "setup-experience-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstLaunchWithoutValidatedAccountShowsWizard() {
        let store = makeStore()
        var config = Config.default
        config.accounts = []

        XCTAssertTrue(store.shouldPresentWizard(config: config))
        XCTAssertTrue(store.shouldShowFinishSetupCTA(config: config))
    }

    func testSkipHidesWizardButKeepsFinishSetupCTAUntilValidated() {
        let store = makeStore()
        var config = Config.default
        config.accounts = []

        store.markCompleted(.skipped)

        XCTAssertFalse(store.shouldPresentWizard(config: config))
        XCTAssertTrue(store.shouldShowFinishSetupCTA(config: config))
    }

    func testDemoModeCanBeEnabledAndDisabled() {
        let store = makeStore()
        var config = Config.default
        config.accounts = []

        store.enableDemoMode()
        XCTAssertEqual(store.state.completionMode, .demoMode)
        XCTAssertTrue(store.state.demoModeEnabled)
        XCTAssertTrue(store.shouldShowFinishSetupCTA(config: config))

        store.disableDemoMode()
        XCTAssertEqual(store.state.completionMode, .skipped)
        XCTAssertFalse(store.state.demoModeEnabled)
    }

    func testLocalValidatedAccountSuppressesWizard() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sage-bar-setup-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let account = Account(name: "Claude Code", type: .claudeCode, localDataPath: tempDir.path)
        var config = Config.default
        config.accounts = [account]

        let store = makeStore()

        XCTAssertTrue(store.hasValidatedAccount(config: config))
        XCTAssertFalse(store.shouldPresentWizard(config: config))
        XCTAssertFalse(store.shouldShowFinishSetupCTA(config: config))
    }

    func testRemoteValidatedAccountSuppressesWizardWhenCredentialExists() throws {
        let account = Account(name: "Anthropic API", type: .anthropicAPI)
        try KeychainManager.store(
            key: "test-key",
            service: AppConstants.keychainService,
            account: account.id.uuidString
        )
        defer { try? KeychainManager.delete(service: AppConstants.keychainService, account: account.id.uuidString) }

        var config = Config.default
        config.accounts = [account]

        let store = makeStore()

        XCTAssertTrue(store.hasValidatedAccount(config: config))
        XCTAssertFalse(store.shouldPresentWizard(config: config))
    }

    private func makeStore(accountValidator: ((Account) -> Bool)? = nil) -> SetupExperienceStore {
        SetupExperienceStore(
            defaults: defaults,
            stateKey: "setupExperienceState",
            currentVersion: 1,
            accountValidator: accountValidator
        )
    }
}
