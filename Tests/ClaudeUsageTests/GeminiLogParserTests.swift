import XCTest
@testable import ClaudeUsage

final class GeminiLogParserTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-log-parser-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func writeSessionFile(_ name: String, json: String) throws {
        let chatsDir = tmpDir.appendingPathComponent("tmp/project/chats")
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        try json.write(to: chatsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testAggregateTodayParsesGeminiMessageTokens() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
          "sessionId": "abc",
          "messages": [
            {
              "timestamp": "\(now)",
              "type": "gemini",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 12, "output": 8, "cached": 3 }
            },
            {
              "timestamp": "\(now)",
              "type": "gemini",
              "model": "gemini-2.5-flash",
              "tokens": { "input": 5, "output": 4, "cached": 1 }
            }
          ]
        }
        """
        try writeSessionFile("session-1.json", json: json)
        let parser = GeminiLogParser(geminiDir: tmpDir)
        let snap = parser.aggregateToday()
        XCTAssertEqual(snap.inputTokens, 17)
        XCTAssertEqual(snap.outputTokens, 12)
        XCTAssertEqual(snap.cacheReadTokens, 4)
        XCTAssertEqual(snap.modelBreakdown.first?.modelId, "gemini-local")
        XCTAssertEqual(snap.costConfidence, .estimated)
    }

    func testAggregateTodayIgnoresMessagesOutsideToday() throws {
        let now = Date()
        let yesterday = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400))
        let today = ISO8601DateFormatter().string(from: now)
        let json = """
        {
          "sessionId": "abc",
          "messages": [
            {
              "timestamp": "\(yesterday)",
              "type": "gemini",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 100, "output": 20, "cached": 10 }
            },
            {
              "timestamp": "\(today)",
              "type": "user",
              "tokens": { "input": 99, "output": 99, "cached": 99 }
            },
            {
              "timestamp": "\(today)",
              "type": "gemini",
              "model": "gemini-2.5-pro",
              "tokens": { "input": 7, "output": 3, "cached": 1 }
            }
          ]
        }
        """
        try writeSessionFile("session-2.json", json: json)
        let parser = GeminiLogParser(geminiDir: tmpDir)
        let snap = parser.aggregateToday()
        XCTAssertEqual(snap.inputTokens, 7)
        XCTAssertEqual(snap.outputTokens, 3)
        XCTAssertEqual(snap.cacheReadTokens, 1)
    }
}
