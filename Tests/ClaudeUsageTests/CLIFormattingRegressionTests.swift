import XCTest

final class CLIFormattingRegressionTests: XCTestCase {
    func testCLIMainDoesNotUseCStringSpecifierForTableRendering() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // ClaudeUsageTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let mainPath = repoRoot.appendingPathComponent("Sources/ClaudeUsageCLI/main.swift")
        let content = try String(contentsOf: mainPath, encoding: .utf8)
        XCTAssertFalse(content.contains("%s"), "CLI table formatting must not use C %s specifiers")
    }
}
