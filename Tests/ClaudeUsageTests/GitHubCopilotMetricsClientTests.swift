import XCTest
@testable import ClaudeUsage

final class GitHubCopilotMetricsClientTests: XCTestCase {
    private func makeSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = handler
        return URLSession(configuration: config)
    }

    func testFetchCurrentSnapshotAggregatesMetricsDay() async throws {
        let session = makeSession { req in
            let body = """
            [
              {
                "date": "2026-02-27",
                "total_active_users": 20,
                "total_engaged_users": 12,
                "copilot_ide_code_completions": {
                  "editors": [
                    {
                      "models": [
                        {
                          "languages": [
                            { "total_code_suggestions": 20, "total_code_acceptances": 5 }
                          ]
                        }
                      ]
                    }
                  ]
                },
                "copilot_ide_chat": {
                  "editors": [
                    {
                      "models": [
                        {
                          "total_chats": 3,
                          "total_chat_insertion_events": 2,
                          "total_chat_copy_events": 1
                        }
                      ]
                    }
                  ]
                },
                "copilot_dotcom_chat": {
                  "models": [
                    { "total_chats": 4 }
                  ]
                },
                "copilot_dotcom_pull_requests": {
                  "repositories": [
                    {
                      "models": [
                        { "total_pr_summaries_created": 2 }
                      ]
                    }
                  ]
                }
              }
            ]
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }

        let client = GitHubCopilotMetricsClient(token: "ghp_test", organization: "acme", session: session)
        let snapshot = try await client.fetchCurrentSnapshot(accountId: UUID(), now: Date())

        XCTAssertEqual(snapshot.inputTokens, 29)
        XCTAssertEqual(snapshot.outputTokens, 14)
        XCTAssertEqual(snapshot.totalCostUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.costConfidence, .estimated)
        XCTAssertEqual(snapshot.modelBreakdown.first?.modelId, "copilot-metrics")
    }

    func testValidateAccessReturnsFalseOnForbidden() async {
        let session = makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = GitHubCopilotMetricsClient(token: "ghp_bad", organization: "acme", session: session)
        let valid = await client.validateAccess()
        XCTAssertFalse(valid)
    }
}
