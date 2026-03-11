import XCTest
@testable import SageBar

final class ClaudeAIQuotaHistoryStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: ClaudeAIQuotaHistoryStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ai-quota-history-\(UUID().uuidString).json")
        store = ClaudeAIQuotaHistoryStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        store = nil
        fileURL = nil
        super.tearDown()
    }

    func testAppendAndReadBackHistory() async {
        let accountId = UUID()
        let entry = ClaudeAIQuotaHistoryEntry(
            accountId: accountId,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            messagesRemaining: 9,
            messagesUsed: 41,
            resetAt: Date(timeIntervalSince1970: 1_700_001_000),
            sessionHealth: .healthy
        )

        await store.append(entry)
        let history = await store.history(for: accountId, limit: 10)

        XCTAssertEqual(history, [entry])
    }

    func testAppendSkipsDuplicateAdjacentState() async {
        let accountId = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ClaudeAIQuotaHistoryEntry(
            accountId: accountId,
            timestamp: timestamp,
            messagesRemaining: 9,
            messagesUsed: 41,
            resetAt: Date(timeIntervalSince1970: 1_700_001_000),
            sessionHealth: .healthy
        )
        let duplicate = ClaudeAIQuotaHistoryEntry(
            accountId: accountId,
            timestamp: timestamp.addingTimeInterval(60),
            messagesRemaining: 9,
            messagesUsed: 41,
            resetAt: Date(timeIntervalSince1970: 1_700_001_000),
            sessionHealth: .healthy
        )

        await store.append(first)
        await store.append(duplicate)
        let history = await store.history(for: accountId, limit: 10)

        XCTAssertEqual(history.count, 1)
    }
}
