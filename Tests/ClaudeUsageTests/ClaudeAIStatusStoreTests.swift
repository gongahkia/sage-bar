import XCTest
@testable import SageBar

final class ClaudeAIStatusStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: ClaudeAIStatusStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ai-status-\(UUID().uuidString).json")
        store = ClaudeAIStatusStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        store = nil
        fileURL = nil
        super.tearDown()
    }

    func testSaveAndLoadStatusRoundTrip() async {
        let status = ClaudeAIStatus(
            accountId: UUID(),
            messagesRemaining: 8,
            messagesUsed: 42,
            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_100),
            lastSuccessfulSyncAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastErrorMessage: nil,
            sessionHealth: .healthy
        )

        await store.save(status)
        let loaded = await store.status(for: status.accountId)

        XCTAssertEqual(loaded, status)
    }

    func testRemoveDeletesStatusForAccount() async {
        let status = ClaudeAIStatus(
            accountId: UUID(),
            messagesRemaining: 8,
            messagesUsed: 42,
            resetAt: nil,
            lastUpdated: Date(),
            lastSuccessfulSyncAt: nil,
            lastErrorMessage: "reauth required",
            sessionHealth: .reauthRequired
        )

        await store.save(status)
        await store.remove(accountId: status.accountId)
        let loaded = await store.status(for: status.accountId)

        XCTAssertNil(loaded)
    }
}
