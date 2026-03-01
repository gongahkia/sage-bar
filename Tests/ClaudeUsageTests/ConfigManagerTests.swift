import XCTest
@testable import ClaudeUsage

final class ConfigManagerTests: XCTestCase {
    private var cm: ConfigManager!
    private var configDir: URL!
    private var configFile: URL!

    override func setUp() {
        super.setUp()
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        configFile = configDir.appendingPathComponent("config.toml")
        cm = ConfigManager(configDir: configDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configDir)
        cm = nil
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

    func testMalformedJSONFallsBackToDefault() throws {
        try "{ invalid-json ".write(to: configFile, atomically: true, encoding: .utf8)
        let loaded = cm.load()
        XCTAssertEqual(loaded.pollIntervalSeconds, Config.default.pollIntervalSeconds)
        XCTAssertNotNil(cm.lastLoadError)
    }

    func testMalformedTOMLFallsBackToDefault() throws {
        try "pollIntervalSeconds = ".write(to: configFile, atomically: true, encoding: .utf8)
        let loaded = cm.load()
        XCTAssertEqual(loaded.pollIntervalSeconds, Config.default.pollIntervalSeconds)
        XCTAssertNotNil(cm.lastLoadError)
    }

    func testTomlFallbackLoadsWhenJSONDecodeFails() throws {
        let accountID = UUID().uuidString
        let toml = """
        schemaVersion = 2
        pollIntervalSeconds = 321

        accounts = [
          { id = "\(accountID)", name = "Local", type = "claudeCode", isActive = true, order = 3, createdAt = "2026-01-01T00:00:00Z" }
        ]
        automations = []

        [tui]
        layout = ["input_tokens"]
        colorScheme = "default"
        showLogo = true
        separatorChar = "-"
        labelWidth = 18

        [display]
        menubarStyle = "icon"
        showBadge = true
        compactMode = false
        dualIcon = false

        [sparkline]
        enabled = true
        windowHours = 168
        style = "cost"
        resolution = 24

        [forecast]
        enabled = true
        showInPopover = true
        showInTUI = false

        [webhook]
        enabled = false
        url = ""
        events = []

        [analytics]
        enabled = true
        showMonthlyView = true
        showHeatmap = false

        [modelOptimizer]
        enabled = true
        cheapThresholdTokens = 1000
        showInPopover = true

        [iCloudSync]
        enabled = false
        localOnly = true
        containerIdentifier = "iCloud.dev.claudeusage"

        [hotkey]
        enabled = true
        modifiers = ["option", "command"]
        key = "c"

        [claudeAI]
        sessionCookie = ""

        [hotkeyConfig]
        primaryKeyCode = 32
        primaryModifiers = ["command", "shift"]
        chordEnabled = false
        chordSecondaryKeyCode = 0
        """
        try toml.write(to: configFile, atomically: true, encoding: .utf8)
        let loaded = cm.load()
        XCTAssertEqual(loaded.pollIntervalSeconds, 321)
        XCTAssertEqual(loaded.accounts.first?.order, 3)
        XCTAssertNil(cm.lastLoadError)
    }
}
