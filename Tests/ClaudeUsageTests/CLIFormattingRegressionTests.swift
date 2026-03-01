import XCTest

final class CLIFormattingRegressionTests: XCTestCase {
    private func cliMainSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // ClaudeUsageTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let mainPath = repoRoot.appendingPathComponent("Sources/ClaudeUsageCLI/main.swift")
        return try String(contentsOf: mainPath, encoding: .utf8)
    }

    func testCLIMainDoesNotUseCStringSpecifierForTableRendering() throws {
        let content = try cliMainSource()
        XCTAssertFalse(content.contains("%s"), "CLI table formatting must not use C %s specifiers")
    }

    func testAccountFilterUsesCaseInsensitiveUUIDMatching() throws {
        let content = try cliMainSource()
        XCTAssertTrue(
            content.contains("matchedSet.contains($0.accountId.uuidString.lowercased())"),
            "CLI account filtering should normalize UUID case before membership checks"
        )
    }

    func testAccountFilterIncludesNameAmbiguityGuard() throws {
        let content = try cliMainSource()
        XCTAssertTrue(
            content.contains("is ambiguous; matched"),
            "CLI account filtering should report ambiguous case-insensitive name matches"
        )
    }
}
