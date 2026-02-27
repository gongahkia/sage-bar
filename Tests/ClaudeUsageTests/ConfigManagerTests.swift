import XCTest
@testable import ClaudeUsage

final class ConfigManagerTests: XCTestCase {
    private let cm = ConfigManager.shared
    private let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/claude-usage/config.toml")
    private var backup: Data?

    override func setUp() {
        super.setUp()
        backup = try? Data(contentsOf: configFile)
        try? FileManager.default.removeItem(at: configFile) // start clean
    }

    override func tearDown() {
        if let backup {
            try? backup.write(to: configFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: configFile)
        }
        super.tearDown()
    }

    func testLoadDefaultsWhenFileAbsent() {
        let config = cm.load()
        let defaults = Config.default
        XCTAssertEqual(config.pollIntervalSeconds, defaults.pollIntervalSeconds)
        XCTAssertEqual(config.accounts.count, defaults.accounts.count)
    }

    func testSaveAndReloadRoundtrip() {
        var config = Config.default
        config.pollIntervalSeconds = 42
        cm.save(config)
        let reloaded = cm.load()
        XCTAssertEqual(reloaded.pollIntervalSeconds, 42)
    }

    func testSaveAndReloadPreservesAccounts() {
        var config = Config.default
        let acct = Account(name: "TestAccount", type: .anthropicAPI, isActive: true)
        config.accounts = [acct]
        cm.save(config)
        let reloaded = cm.load()
        XCTAssertEqual(reloaded.accounts.first?.name, "TestAccount")
    }
}
