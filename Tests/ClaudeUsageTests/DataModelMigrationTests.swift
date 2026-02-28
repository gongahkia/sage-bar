import XCTest
@testable import ClaudeUsage

final class DataModelMigrationTests: XCTestCase {
    func testDecodeLegacySnapshotWithoutCostConfidenceDefaultsToBillingGrade() throws {
        let id = UUID()
        let json = """
        {
          "accountId": "\(id.uuidString)",
          "timestamp": "2026-01-01T00:00:00Z",
          "inputTokens": 100,
          "outputTokens": 50,
          "cacheCreationTokens": 0,
          "cacheReadTokens": 0,
          "totalCostUSD": 1.5,
          "modelBreakdown": []
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.costConfidence, .billingGrade)
    }

    func testDecodeLegacyClaudeAISnapshotInfersEstimatedConfidence() throws {
        let id = UUID()
        let json = """
        {
          "accountId": "\(id.uuidString)",
          "timestamp": "2026-01-01T00:00:00Z",
          "inputTokens": 12,
          "outputTokens": 0,
          "cacheCreationTokens": 0,
          "cacheReadTokens": 0,
          "totalCostUSD": 0,
          "modelBreakdown": [
            {
              "modelId": "claude-ai-web",
              "inputTokens": 5,
              "outputTokens": 0,
              "costUSD": 0
            }
          ]
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.costConfidence, .estimated)
    }

    func testDecodeLegacyCodexSnapshotInfersEstimatedConfidence() throws {
        let id = UUID()
        let json = """
        {
          "accountId": "\(id.uuidString)",
          "timestamp": "2026-01-01T00:00:00Z",
          "inputTokens": 50,
          "outputTokens": 11,
          "cacheCreationTokens": 0,
          "cacheReadTokens": 20,
          "totalCostUSD": 0,
          "modelBreakdown": [
            {
              "modelId": "codex-local",
              "inputTokens": 50,
              "outputTokens": 11,
              "cacheTokens": 20,
              "costUSD": 0
            }
          ]
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.costConfidence, .estimated)
    }
}
