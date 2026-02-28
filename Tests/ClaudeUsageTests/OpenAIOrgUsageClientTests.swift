import XCTest
@testable import ClaudeUsage

final class OpenAIOrgUsageClientTests: XCTestCase {
    private func makeSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = handler
        return URLSession(configuration: config)
    }

    func testFetchCurrentSnapshotCombinesUsageAndCosts() async throws {
        let session = makeSession { req in
            guard let url = req.url else { throw URLError(.badURL) }
            if url.path.contains("/v1/organization/usage/completions") {
                let body = """
                {
                  "data": [
                    {
                      "start_time": 1735689600,
                      "end_time": 1735776000,
                      "results": [
                        {
                          "model": "gpt-4o",
                          "input_tokens": 120,
                          "output_tokens": 40,
                          "input_cached_tokens": 15
                        }
                      ]
                    }
                  ]
                }
                """
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(body.utf8))
            }
            if url.path.contains("/v1/organization/costs") {
                let body = """
                {
                  "data": [
                    {
                      "start_time": 1735689600,
                      "end_time": 1735776000,
                      "results": [
                        {
                          "line_item": "gpt-4o",
                          "amount": { "value": 1.75, "currency": "usd" }
                        }
                      ]
                    }
                  ]
                }
                """
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(body.utf8))
            }
            throw URLError(.unsupportedURL)
        }

        let client = OpenAIOrgUsageClient(adminAPIKey: "admin-key", session: session)
        let snapshot = try await client.fetchCurrentSnapshot(accountId: UUID(), now: Date(timeIntervalSince1970: 1_735_776_000))

        XCTAssertEqual(snapshot.inputTokens, 120)
        XCTAssertEqual(snapshot.outputTokens, 40)
        XCTAssertEqual(snapshot.cacheReadTokens, 15)
        XCTAssertEqual(snapshot.totalCostUSD, 1.75, accuracy: 0.0001)
        XCTAssertEqual(snapshot.costConfidence, .billingGrade)
        XCTAssertEqual(snapshot.modelBreakdown.first?.modelId, "openai-org")
    }

    func testValidateAccessReturnsFalseOnUnauthorized() async {
        let session = makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = OpenAIOrgUsageClient(adminAPIKey: "bad-key", session: session)
        let valid = await client.validateAccess(now: Date(timeIntervalSince1970: 1_735_776_000))
        XCTAssertFalse(valid)
    }
}
