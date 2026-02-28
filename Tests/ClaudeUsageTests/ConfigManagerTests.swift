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

    // MARK: - Task 65: partial config missing optional sections → defaults

    func testMissingOptionalSectionsLoadWithDefaults() {
        let minimalJSON = "{\"pollIntervalSeconds\":999}" // missing webhook, sparkline, forecast etc.
        try? minimalJSON.write(to: configFile, atomically: true, encoding: .utf8)
        let config = cm.load() // JSONDecoder throws on partial data → Config.default
        XCTAssertNotNil(config, "load must not crash on partial config")
        XCTAssertEqual(config.pollIntervalSeconds, Config.default.pollIntervalSeconds,
                       "missing optional sections → defaults used")
    }

    // MARK: - Task 66: atomic write failure leaves original intact

    func testAtomicWritePreservesOriginalOnFailure() throws {
        var base = Config.default; base.pollIntervalSeconds = 77
        cm.save(base)
        let dir = configFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        var modified = base; modified.pollIntervalSeconds = 999
        cm.save(modified) // write to .tmp fails (dir read-only) → catch {} → original intact
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let loaded = cm.load()
        XCTAssertEqual(loaded.pollIntervalSeconds, 77, "original must be intact after failed atomic write")
    }
}
