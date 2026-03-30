import XCTest
@testable import SageBar

final class AppIntentsSmokeTests: XCTestCase {
    func testGetDiagnosticsSnapshotIntentReturnsJSON() async throws {
        let result = try await GetDiagnosticsSnapshotIntent().perform()
        guard let payload = result.value,
              let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("expected diagnostics intent to return valid JSON payload")
        }

        XCTAssertNotNil(object["generatedAt"])
        XCTAssertNotNil(object["polling"])
        XCTAssertNotNil(object["recentErrors"])
    }

    func testShortcutsProviderRegistersDiagnosticsIntent() {
        let shortcuts = SageBarShortcutsProvider.appShortcuts
        XCTAssertEqual(shortcuts.count, 5)
        let hasDiagnosticsPhrase = shortcuts.contains { shortcut in
            Mirror(reflecting: shortcut).children.contains { child in
                guard child.label == "basePhraseTemplates",
                      let phrases = child.value as? [String] else {
                    return false
                }
                return phrases.contains { $0.localizedCaseInsensitiveContains("diagnostics") }
            }
        }
        XCTAssertTrue(
            hasDiagnosticsPhrase,
            "expected diagnostics intent phrase to be present in AppShortcutsProvider"
        )
    }
}
