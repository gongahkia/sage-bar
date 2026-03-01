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

    func testInvalidSinceDateHasExplicitErrorGuard() throws {
        let content = try cliMainSource()
        XCTAssertTrue(
            content.contains("Invalid --since date"),
            "CLI should emit explicit parse errors for invalid --since inputs"
        )
    }

    func testHistoryPathNormalizesCumulativeSnapshotsByAccountDay() throws {
        let content = try cliMainSource()
        XCTAssertTrue(
            content.contains("let normalized = normalizeByAccountWithinDay(snaps)"),
            "CLI --history should normalize cumulative snapshots before daily aggregation"
        )
    }

    func testHeatmapPathNormalizesCumulativeSnapshotsByAccountDay() throws {
        let content = try cliMainSource()
        XCTAssertTrue(
            content.contains("let normalizedForHeatmap = Dictionary(grouping: snapshots)"),
            "CLI --heatmap should derive a normalized snapshot set before populating the grid"
        )
        XCTAssertTrue(
            content.contains(".flatMap { normalizeByAccountWithinDay($0) }"),
            "CLI --heatmap should normalize cumulative snapshots within each account/day bucket"
        )
    }
}
