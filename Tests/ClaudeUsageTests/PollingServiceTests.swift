import XCTest
@testable import ClaudeUsage

final class PollingServiceTests: XCTestCase {
    private let accountId = UUID()
    private let service = AppConstants.keychainSessionTokenService

    override func setUp() async throws {
        try await super.setUp()
        // register mock so default URLSession network calls are intercepted
        URLProtocol.registerClass(MockURLProtocol.self)
        // make network calls fail (simulates nil return from fetchUsage)
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        // store a fake token so PollingService doesn't bail at keychain step
        try KeychainManager.store(key: "fake-session-token", service: service, account: accountId.uuidString)
        // pre-populate a non-stale prior snapshot so the fallback has something to mark stale
        let prior = UsageSnapshot(
            accountId: accountId, timestamp: Date().addingTimeInterval(-120),
            inputTokens: 5, outputTokens: 3, cacheCreationTokens: 0, cacheReadTokens: 0,
            totalCostUSD: 0, modelBreakdown: [ModelUsage(modelId: "claude-ai-web", inputTokens: 30, outputTokens: 0, costUSD: 0)]
        )
        CacheManager.shared.append(prior)
        // wait for async append
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        try? KeychainManager.delete(service: service, account: accountId.uuidString)
        try await super.tearDown()
    }

    func testClaudeAIBranchStoresStaleSnapshotWhenFetchFails() async {
        let account = Account(name: "Test AI", type: .claudeAI, isActive: true)
        // mirror the accountId we pre-seeded
        var a = account
        // use reflection-safe workaround: re-create prior snapshot with same id
        let testAccount = Account(name: "Test AI", type: .claudeAI, isActive: true)
        // since Account.init assigns a new UUID, test via explicit prior + real account id
        let prior = UsageSnapshot(
            accountId: testAccount.id, timestamp: Date().addingTimeInterval(-60),
            inputTokens: 10, outputTokens: 2, cacheCreationTokens: 0, cacheReadTokens: 0,
            totalCostUSD: 0, modelBreakdown: [ModelUsage(modelId: "claude-ai-web", inputTokens: 25, outputTokens: 0, costUSD: 0)]
        )
        CacheManager.shared.append(prior)
        try? await Task.sleep(nanoseconds: 300_000_000)
        // also store keychain token for this account
        try? KeychainManager.store(key: "fake-token-2", service: service, account: testAccount.id.uuidString)
        defer { try? KeychainManager.delete(service: service, account: testAccount.id.uuidString) }
        await PollingService.shared.fetchAndStore(account: testAccount, config: .default)
        try? await Task.sleep(nanoseconds: 300_000_000) // allow cache append to complete
        let latest = CacheManager.shared.latest(forAccount: testAccount.id)
        XCTAssertEqual(latest?.isStale, true, "snapshot should be marked stale when fetchUsage returns nil")
    }
}
