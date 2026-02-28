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

    // MARK: - Task 54: 503 triggers retry; total attempts = maxRetries+1

    func test503TriggersRetryExactCount() async {
        var callCount = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { req in
            callCount += 1
            let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let mockSession = URLSession(configuration: config)
        let svc = WebhookService(session: mockSession, maxRetries: 2)
        let whConfig = WebhookConfig(enabled: true, url: "https://example.com/hook", events: [], payloadTemplate: nil)
        do {
            try await svc.send(event: .dailyDigest, snapshot: snap(), config: whConfig)
        } catch {}
        XCTAssertEqual(callCount, svc.maxRetries + 1, "should attempt initial + maxRetries times on 503")
    }

    // MARK: - Task 55: URLSession timeout logs via ErrorLogger

    func testTimeoutLogsError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
        let mockSession = URLSession(configuration: config)
        let svc = WebhookService(session: mockSession, maxRetries: 0)
        let whConfig = WebhookConfig(enabled: true, url: "https://example.com/hook", events: [], payloadTemplate: nil)
        do { try await svc.send(event: .dailyDigest, snapshot: snap(), config: whConfig) } catch {}
        let exp = expectation(description: "ErrorLogger set after timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertNotNil(ErrorLogger.shared.lastError, "timeout should log via ErrorLogger")
    }

    // MARK: - Task 56: non-https URL rejected before any network call

    func testNonHttpsURLRejectedWithoutNetworkCall() async {
        var called = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { _ in called = true; throw URLError(.unknown) }
        let mockSession = URLSession(configuration: config)
        let svc = WebhookService(session: mockSession, maxRetries: 0)
        let whConfig = WebhookConfig(enabled: true, url: "http://example.com/hook", events: [], payloadTemplate: nil)
        do { try await svc.send(event: .dailyDigest, snapshot: snap(), config: whConfig) } catch {}
        XCTAssertFalse(called, "http:// URL should be rejected without making any network call")
    }
}
