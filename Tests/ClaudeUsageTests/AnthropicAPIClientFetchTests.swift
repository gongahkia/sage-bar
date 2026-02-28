import XCTest
@testable import ClaudeUsage

private func mockClient(statusCode: Int, body: Data, headers: [String: String] = [:]) -> AnthropicAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.requestHandler = { req in
        let resp = HTTPURLResponse(url: req.url!, statusCode: statusCode,
            httpVersion: nil, headerFields: headers)!
        return (resp, body)
    }
    return AnthropicAPIClient(apiKey: "test", session: URLSession(configuration: config))
}

private let validBody: Data = {
    let json = """
    {"data":[{"start_time":"2025-01-01T00:00:00Z","end_time":"2025-01-01T01:00:00Z",
    "input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,
    "cache_read_input_tokens":0,"model":"claude-sonnet-4-6"}],
    "has_more":false,"first_id":null,"last_id":null}
    """
    return Data(json.utf8)
}()

final class AnthropicAPIClientFetchTests: XCTestCase {
    func test200ReturnsDecodedResponse() async throws {
        let client = mockClient(statusCode: 200, body: validBody)
        let resp = try await client.fetchUsage(startDate: Date(), endDate: Date())
        XCTAssertEqual(resp.data.count, 1)
    }

    func test401ThrowsInvalidKey() async {
        let client = mockClient(statusCode: 401, body: Data())
        do {
            _ = try await client.fetchUsage(startDate: Date(), endDate: Date())
            XCTFail("expected throw")
        } catch APIError.invalidKey { /* pass */ }
        catch { XCTFail("wrong error: \(error)") }
    }

    func test429ThrowsRateLimitedWithRetryAfter() async {
        let client = mockClient(statusCode: 429, body: Data(), headers: ["Retry-After": "30"])
        do {
            _ = try await client.fetchUsage(startDate: Date(), endDate: Date())
            XCTFail("expected throw")
        } catch APIError.rateLimited(let after) {
            XCTAssertEqual(after, 30)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test500ThrowsServerError() async {
        let client = mockClient(statusCode: 500, body: Data())
        do {
            _ = try await client.fetchUsage(startDate: Date(), endDate: Date())
            XCTFail("expected throw")
        } catch APIError.serverError(let code) {
            XCTAssertEqual(code, 500)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testMalformedJSONThrowsNetworkError() async {
        let client = mockClient(statusCode: 200, body: Data("not json".utf8))
        do {
            _ = try await client.fetchUsage(startDate: Date(), endDate: Date())
            XCTFail("expected throw")
        } catch APIError.networkError { /* pass */ }
        catch { XCTFail("wrong error: \(error)") }
    }
}
