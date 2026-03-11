import XCTest
@testable import SageBar

// MARK: – Tests

final class ClaudeAIClientTests: XCTestCase {
    private func makeClient(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> ClaudeAIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = handler
        return ClaudeAIClient(sessionToken: "test-token", session: URLSession(configuration: config))
    }

    func testFetchUsage200ReturnsCorrectValues() async {
        let json = """
        {"messageLimit":{"remaining":45,"used":15,"resetAt":"2026-03-12T10:00:00Z"}}
        """
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }
        let usage = await client.fetchUsage()
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.messagesRemaining, 45)
        XCTAssertEqual(usage?.messagesUsed, 15)
        XCTAssertEqual(usage?.resetAt, ISO8601DateFormatter().date(from: "2026-03-12T10:00:00Z"))
    }

    func testFetchUsageNetworkErrorReturnsNil() async {
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let usage = await client.fetchUsage()
        XCTAssertNil(usage, "network error should produce nil, not throw")
    }

    func testFetchUsage401ReturnsNil() async {
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let usage = await client.fetchUsage()
        XCTAssertNil(usage)
    }
}
