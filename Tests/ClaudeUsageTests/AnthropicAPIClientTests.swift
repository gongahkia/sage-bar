import XCTest
@testable import ClaudeUsage

final class AnthropicAPIClientTests: XCTestCase {
    private let accountId = UUID()
    private let client = AnthropicAPIClient(apiKey: "test-key")

    private func period(model: String, input: Int = 1_000_000, output: Int = 1_000_000,
                        cacheCreate: Int = 0, cacheRead: Int = 0) -> AnthropicUsagePeriod {
        AnthropicUsagePeriod(start_time: "2025-01-01T00:00:00Z", end_time: "2025-01-01T01:00:00Z",
            input_tokens: input, output_tokens: output,
            cache_creation_input_tokens: cacheCreate, cache_read_input_tokens: cacheRead, model: model)
    }

    private func response(_ periods: [AnthropicUsagePeriod]) -> AnthropicUsageResponse {
        AnthropicUsageResponse(data: periods, has_more: false, first_id: nil, last_id: nil)
    }

    // MARK: - convertToSnapshots

    func testKnownModelPrefixMatchCostCalculated() {
        let snaps = client.convertToSnapshots(response([period(model: "claude-sonnet-4-6")]), accountId: accountId)
        XCTAssertEqual(snaps.count, 1)
        // 1M input @ $3/1M + 1M output @ $15/1M = $18
        XCTAssertEqual(snaps[0].totalCostUSD, 18.0, accuracy: 0.001)
    }

    func testUnknownModelYearsZeroCost() {
        let snaps = client.convertToSnapshots(response([period(model: "unknown-model-xyz")]), accountId: accountId)
        XCTAssertEqual(snaps[0].totalCostUSD, 0.0)
    }

    func testCacheTokensPreservedInSnapshot() {
        let snaps = client.convertToSnapshots(
            response([period(model: "claude-3-haiku", input: 0, output: 0, cacheCreate: 500, cacheRead: 200)]),
            accountId: accountId)
        XCTAssertEqual(snaps[0].cacheCreationTokens, 500)
        XCTAssertEqual(snaps[0].cacheReadTokens, 200)
    }

    func testMultiPeriodResponseMapsToMultipleSnapshots() {
        let periods = [
            period(model: "claude-sonnet-4-6", input: 1000, output: 500),
            period(model: "claude-3-haiku", input: 2000, output: 1000),
        ]
        let snaps = client.convertToSnapshots(response(periods), accountId: accountId)
        XCTAssertEqual(snaps.count, 2)
        XCTAssertTrue(snaps.allSatisfy { $0.accountId == accountId })
    }

    func testAccountIdIsPreservedInAllSnapshots() {
        let snaps = client.convertToSnapshots(
            response([period(model: "claude-sonnet-4-6"), period(model: "claude-3-haiku")]),
            accountId: accountId)
        XCTAssertTrue(snaps.allSatisfy { $0.accountId == accountId })
    }
}
