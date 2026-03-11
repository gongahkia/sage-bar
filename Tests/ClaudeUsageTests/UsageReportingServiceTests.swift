import XCTest
@testable import SageBar

final class UsageReportingServiceTests: XCTestCase {
    func testSummaryTextIncludesGroupProviderConfidenceAndLastSync() {
        let account = Account(name: "Client Spend", type: .anthropicAPI, groupLabel: "Client A")
        let lastSync = Date(timeIntervalSince1970: 1_700_000_000)
        CacheManager.shared.saveLastSuccess(lastSync, forAccount: account.id)

        let summary = UsageReportingService.summaryText(for: account, among: [account])

        XCTAssertTrue(summary.contains("Account: Client Spend • Client A"))
        XCTAssertTrue(summary.contains("Group: Client A"))
        XCTAssertTrue(summary.contains("Provider: Anthropic API"))
        XCTAssertTrue(summary.contains("Cost Confidence: Billing-grade"))
        XCTAssertTrue(summary.contains("Last Sync: 2023-11-14T22:13:20Z"))
    }

    func testCSVContentsUsesStableHeaderOrder() {
        let account = Account(name: "Workspace", type: .claudeAI, groupLabel: "Studio")

        let csv = UsageReportingService.csvContents(for: [account])
        let lines = csv.components(separatedBy: "\n")

        XCTAssertEqual(
            lines.first,
            "account_id,account_name,group_label,provider_type,input_tokens,output_tokens,cache_tokens,total_cost_usd,cost_confidence,last_updated"
        )
        XCTAssertTrue(lines[1].contains("\"Workspace\""))
        XCTAssertTrue(lines[1].contains("\"Studio\""))
        XCTAssertTrue(lines[1].contains("\"\(AccountType.claudeAI.rawValue)\""))
    }

    func testGroupRollupRowsAggregateAccountsInSelectedRange() {
        let first = Account(name: "First", type: .anthropicAPI, groupLabel: "Client A")
        let second = Account(name: "Second", type: .anthropicAPI, groupLabel: "Client A")
        let timestamp = Date().addingTimeInterval(-60)
        CacheManager.shared.append(
            UsageSnapshot(
                accountId: first.id,
                timestamp: timestamp,
                inputTokens: 100,
                outputTokens: 50,
                cacheCreationTokens: 10,
                cacheReadTokens: 5,
                totalCostUSD: 1.25,
                modelBreakdown: []
            )
        )
        CacheManager.shared.append(
            UsageSnapshot(
                accountId: second.id,
                timestamp: timestamp,
                inputTokens: 200,
                outputTokens: 25,
                cacheCreationTokens: 0,
                cacheReadTokens: 10,
                totalCostUSD: 2.75,
                modelBreakdown: []
            )
        )

        let interval = DateInterval(start: timestamp.addingTimeInterval(-60), end: timestamp.addingTimeInterval(60))
        let rows = UsageReportingService.groupRollupRows(for: [first, second], in: interval)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.groupLabel, "Client A")
        XCTAssertEqual(rows.first?.inputTokens, 300)
        XCTAssertEqual(rows.first?.outputTokens, 75)
        XCTAssertEqual(rows.first?.cacheTokens, 25)
        XCTAssertEqual(rows.first?.totalCostUSD ?? 0, 4.0, accuracy: 0.0001)
    }

    func testSummaryTextForRangeIncludesPeriodLabel() {
        let account = Account(name: "Range Test", type: .anthropicAPI, groupLabel: "Client A")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = DateInterval(start: start, end: start.addingTimeInterval(86_400))

        let summary = UsageReportingService.summaryText(for: account, among: [account], in: interval)

        XCTAssertTrue(summary.contains("Period:"))
        XCTAssertTrue(summary.contains("Cost (USD):"))
    }
}
