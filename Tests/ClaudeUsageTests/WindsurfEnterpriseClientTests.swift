import XCTest
@testable import SageBar

final class WindsurfEnterpriseClientTests: XCTestCase {
    private func makeSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = handler
        return URLSession(configuration: config)
    }

    func testFetchCurrentSnapshotUsesAnalyticsAndAddOnCredits() async throws {
        let session = makeSession { req in
            guard let url = req.url else { throw URLError(.badURL) }
            if url.path.contains("/api/v1/UserPageAnalytics") {
                let body = """
                {
                  "userTableStats": [
                    { "userId": "u1", "teamStatus": "approved", "promptCreditsUsed": 15 },
                    { "userId": "u2", "teamStatus": "approved", "promptCreditsUsed": 25 }
                  ]
                }
                """
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(body.utf8))
            }
            if url.path.contains("/api/v1/GetTeamCreditBalance") {
                let body = """
                {
                  "promptCreditsPerSeat": 20,
                  "totalSeats": 5,
                  "promptCreditsUsed": 100,
                  "addOnCreditsUsed": 50
                }
                """
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(body.utf8))
            }
            throw URLError(.unsupportedURL)
        }

        let client = WindsurfEnterpriseClient(serviceKey: "svc-key", groupName: nil, session: session)
        let snapshot = try await client.fetchCurrentSnapshot(accountId: UUID(), now: Date())

        XCTAssertEqual(snapshot.inputTokens, 40)
        XCTAssertEqual(snapshot.outputTokens, 0)
        XCTAssertEqual(snapshot.totalCostUSD, 2.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.costConfidence, .estimated)
        XCTAssertEqual(snapshot.modelBreakdown.first?.modelId, "windsurf-enterprise")
    }

    func testValidateAccessReturnsFalseWhenUnauthorized() async {
        let session = makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = WindsurfEnterpriseClient(serviceKey: "bad-key", session: session)
        let valid = await client.validateAccess()
        XCTAssertFalse(valid)
    }
}
