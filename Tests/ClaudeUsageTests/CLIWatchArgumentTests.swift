import XCTest
import ClaudeUsageCore

final class CLIWatchArgumentTests: XCTestCase {
    func testRemovingWatchFlagKeepsFollowingArguments() {
        let input = ["--watch", "5", "--account", "abc", "--since", "2026-01-01"]
        let output = CLIArgumentUtils.removingWatchFlag(arguments: input)
        XCTAssertEqual(output, ["--account", "abc", "--since", "2026-01-01"])
    }

    func testRemovingWatchFlagDoesNotRemoveMatchingNumericValuesElsewhere() {
        let input = ["--watch", "5", "--account", "5", "--since", "2026-01-01"]
        let output = CLIArgumentUtils.removingWatchFlag(arguments: input)
        XCTAssertEqual(output, ["--account", "5", "--since", "2026-01-01"])
    }
}
