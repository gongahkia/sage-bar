import XCTest
@testable import SageBar

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

    func testBurnRateEventAddsBurnRateFieldsToPayload() {
        let data = service.buildPayload(
            event: .burnRateBreached(thresholdUSDPerHour: 10, burnRateUSDPerHour: 12.5),
            snapshot: snap(cost: 12.5),
            template: nil
        )
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["event"] as? String, "burn_rate")
        XCTAssertEqual(obj?["threshold_usd_per_hour"] as? Double ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(obj?["burn_rate_usd_per_hour"] as? Double ?? 0, 12.5, accuracy: 0.001)
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
        let whConfig = WebhookConfig(enabled: true, url: "https://example.com/hook", events: [], payloadTemplate: nil, allowedHosts: ["example.com"])
        do {
            try await svc.send(event: .dailyDigest, snapshot: snap(), config: whConfig)
        } catch {}
        XCTAssertEqual(callCount, svc.maxRetries + 1, "should attempt initial + maxRetries times on 503")
    }

    func testIdempotencyHeadersPersistAcrossRetries() async {
        var callCount = 0
        var idempotencyKeys: [String] = []
        var xIdempotencyKeys: [String] = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { req in
            callCount += 1
            idempotencyKeys.append(req.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
            xIdempotencyKeys.append(req.value(forHTTPHeaderField: "X-Idempotency-Key") ?? "")
            let code = callCount == 1 ? 503 : 200
            let resp = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let mockSession = URLSession(configuration: config)
        let svc = WebhookService(session: mockSession, maxRetries: 2, baseRetryDelayNanos: 1_000_000)
        let whConfig = WebhookConfig(enabled: true, url: "https://example.com/hook", events: [], payloadTemplate: nil, allowedHosts: ["example.com"])

        do {
            try await svc.send(event: .dailyDigest, snapshot: snap(), config: whConfig)
        } catch {
            XCTFail("send should succeed on retry: \(error)")
        }

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(Set(idempotencyKeys).count, 1, "Idempotency-Key must stay constant across retries")
        XCTAssertEqual(Set(xIdempotencyKeys).count, 1, "X-Idempotency-Key must stay constant across retries")
        XCTAssertFalse((idempotencyKeys.first ?? "").isEmpty)
        XCTAssertEqual(idempotencyKeys.first, xIdempotencyKeys.first)
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

    func testSendTestRejectsDisallowedHostWithoutNetworkCall() async {
        var called = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { _ in
            called = true
            let resp = HTTPURLResponse(url: URL(string: "https://example.com/hook")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let mockSession = URLSession(configuration: config)
        let svc = WebhookService(session: mockSession, maxRetries: 0)
        let whConfig = WebhookConfig(
            enabled: true,
            url: "https://example.com/hook",
            events: [],
            payloadTemplate: nil,
            allowedHosts: ["hooks.slack.com"]
        )

        let result = await svc.sendTest(config: whConfig)
        XCTAssertFalse(called, "sendTest should reject disallowed hosts before making any network call")
        if case .success = result {
            XCTFail("sendTest should fail when host is not allowed")
        }
    }

    func testInvalidJSONTemplateRejectedBeforeDispatch() async {
        var called = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { _ in
            called = true
            let resp = HTTPURLResponse(url: URL(string: "https://example.com/hook")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let mockSession = URLSession(configuration: config)
        let svc = WebhookService(session: mockSession, maxRetries: 0)
        let invalidTemplate = "{\"event\":\"{{event}}\",\"cost\":{{cost}}" // missing closing brace
        let whConfig = WebhookConfig(enabled: true, url: "https://example.com/hook", events: [], payloadTemplate: invalidTemplate, allowedHosts: ["example.com"])

        do {
            try await svc.send(event: .dailyDigest, snapshot: snap(), config: whConfig)
            XCTFail("invalid JSON template should throw")
        } catch let error as APIError {
            guard case .decodingFailed = error else {
                XCTFail("expected decodingFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertFalse(called, "invalid JSON template must fail before any network call")
    }

    func testTemplateSubstitutionCanProduceInvalidJSONAndIsRejected() async {
        var called = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { _ in
            called = true
            let resp = HTTPURLResponse(url: URL(string: "https://example.com/hook")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let mockSession = URLSession(configuration: config)
        let svc = WebhookService(session: mockSession, maxRetries: 0)
        let template = "{\"event\":\"{{event}}\",\"date\":{{date}}}"
        let whConfig = WebhookConfig(enabled: true, url: "https://example.com/hook", events: [], payloadTemplate: template, allowedHosts: ["example.com"])

        do {
            try await svc.send(event: .dailyDigest, snapshot: snap(), config: whConfig)
            XCTFail("template should be rejected after substitution creates invalid JSON")
        } catch let error as APIError {
            guard case .decodingFailed = error else {
                XCTFail("expected decodingFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertFalse(called, "invalid post-substitution JSON must fail before network dispatch")
    }

    func testMalformedJSONArrayTemplateRejectedBeforeDispatch() async {
        var called = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { _ in
            called = true
            let resp = HTTPURLResponse(url: URL(string: "https://example.com/hook")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let mockSession = URLSession(configuration: config)
        let svc = WebhookService(session: mockSession, maxRetries: 0)
        let template = "[{\"event\":\"{{event}}\"}"
        let whConfig = WebhookConfig(enabled: true, url: "https://example.com/hook", events: [], payloadTemplate: template, allowedHosts: ["example.com"])

        do {
            try await svc.send(event: .dailyDigest, snapshot: snap(), config: whConfig)
            XCTFail("malformed JSON array template should throw")
        } catch let error as APIError {
            guard case .decodingFailed = error else {
                XCTFail("expected decodingFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertFalse(called, "malformed JSON array template must fail before network dispatch")
    }
}
