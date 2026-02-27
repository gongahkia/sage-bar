import XCTest
@testable import ClaudeUsage

final class WebhookServiceTests: XCTestCase {
    private let service = WebhookService()
    private let accountId = UUID()

    private func snap(cost: Double = 3.14) -> UsageSnapshot {
        UsageSnapshot(accountId: accountId, timestamp: Date(), inputTokens: 100, outputTokens: 50,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: cost, modelBreakdown: [])
    }

    // MARK: - buildPayload

    func testTemplateSubstitution() {
        let tpl = """
        {"event":"{{event}}","cost":"{{cost}}","tokens":"{{tokens}}","acct":"{{account}}"}
        """
        let data = service.buildPayload(event: .thresholdBreached(limitUSD: 10), snapshot: snap(), template: tpl)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.contains("\"threshold\""))
        XCTAssertTrue(str.contains("3.1400"))
        XCTAssertTrue(str.contains("150")) // 100+50
        XCTAssertTrue(str.contains(accountId.uuidString))
    }

    func testNilTemplateFallsBackToJSONPayload() {
        let data = service.buildPayload(event: .dailyDigest, snapshot: snap(), template: nil)
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["event"] as? String, "daily_digest")
        XCTAssertEqual(obj?["cost_usd"] as? Double ?? 0, 3.14, accuracy: 0.001)
    }

    func testEmptyTemplateFallsBackToJSONPayload() {
        let data = service.buildPayload(event: .weeklyDigest, snapshot: snap(), template: "")
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["event"] as? String, "weekly_summary")
    }

    func testSendDisabledConfigIsNoOp() async {
        let config = WebhookConfig(enabled: false, url: "https://example.com", events: [], payloadTemplate: nil)
        do {
            try await service.send(event: .dailyDigest, snapshot: snap(), config: config)
        } catch {
            XCTFail("should not throw when disabled: \(error)")
        }
    }

    func testSendEmptyURLIsNoOp() async {
        let config = WebhookConfig(enabled: true, url: "", events: [], payloadTemplate: nil)
        do {
            try await service.send(event: .dailyDigest, snapshot: snap(), config: config)
        } catch {
            XCTFail("should not throw on empty URL: \(error)")
        }
    }
}
