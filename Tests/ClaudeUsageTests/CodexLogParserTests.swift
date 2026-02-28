import XCTest
@testable import ClaudeUsage

final class CodexLogParserTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func writeJSONL(_ lines: [String], to file: URL) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func tokenCountLine(
        timestamp: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoningOutput: Int
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cachedInput),"output_tokens":\(output),"reasoning_output_tokens":\(reasoningOutput),"total_tokens":0},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"model_context_window":258400},"rate_limits":null}}
        """
    }

    func testParseFileValidTokenCountJSONL() throws {
        let sessionsDir = tmpDir.appendingPathComponent("sessions/2026/02/28")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let file = sessionsDir.appendingPathComponent("rollout.jsonl")
        let now = ISO8601DateFormatter().string(from: Date())
        try writeJSONL([
            #"{"timestamp":"\#(now)","type":"session_meta","payload":{"id":"abc"}}"#,
            tokenCountLine(timestamp: now, input: 100, cachedInput: 50, output: 10, reasoningOutput: 4),
        ], to: file)

        let parser = CodexLogParser(codexDir: tmpDir)
        let entries = parser.parseFile(file)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].payload?.type, "token_count")
        XCTAssertEqual(entries[1].payload?.info?.total_token_usage?.input_tokens, 100)
        XCTAssertEqual(entries[1].payload?.info?.total_token_usage?.cached_input_tokens, 50)
    }

    func testAggregateTodayTracksCumulativeDeltasWithoutDoubleCounting() throws {
        let sessionsDir = tmpDir.appendingPathComponent("sessions/2026/02/28")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let file = sessionsDir.appendingPathComponent("rollout.jsonl")
        let checkpoint = tmpDir.appendingPathComponent("codex-checkpoints.json")
        let accumulator = tmpDir.appendingPathComponent("codex-accumulator.json")
        let totals = tmpDir.appendingPathComponent("codex-totals.json")
        let now = ISO8601DateFormatter().string(from: Date())

        try writeJSONL([
            tokenCountLine(timestamp: now, input: 100, cachedInput: 40, output: 20, reasoningOutput: 10),
            tokenCountLine(timestamp: now, input: 150, cachedInput: 60, output: 30, reasoningOutput: 12),
        ], to: file)

        let parser = CodexLogParser(
            codexDir: tmpDir,
            checkpointFile: checkpoint,
            accumulatorFile: accumulator,
            fileTotalsFile: totals
        )

        let first = parser.aggregateToday()
        XCTAssertEqual(first.inputTokens, 150)
        XCTAssertEqual(first.outputTokens, 42) // output + reasoningOutput
        XCTAssertEqual(first.cacheReadTokens, 60)

        let second = parser.aggregateToday()
        XCTAssertEqual(second.inputTokens, 150, "unchanged files must not be re-ingested")
        XCTAssertEqual(second.outputTokens, 42)
        XCTAssertEqual(second.cacheReadTokens, 60)

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(
            Data(
                (tokenCountLine(timestamp: now, input: 180, cachedInput: 75, output: 35, reasoningOutput: 15) + "\n").utf8
            )
        )
        try handle.close()

        let third = parser.aggregateToday()
        XCTAssertEqual(third.inputTokens, 180)
        XCTAssertEqual(third.outputTokens, 50)
        XCTAssertEqual(third.cacheReadTokens, 75)
    }

    func testAggregateTodayAccumulatorSurvivesRestart() throws {
        let sessionsDir = tmpDir.appendingPathComponent("sessions/2026/02/28")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let file = sessionsDir.appendingPathComponent("rollout.jsonl")
        let checkpoint = tmpDir.appendingPathComponent("codex-checkpoints.json")
        let accumulator = tmpDir.appendingPathComponent("codex-accumulator.json")
        let totals = tmpDir.appendingPathComponent("codex-totals.json")
        let now = ISO8601DateFormatter().string(from: Date())

        try writeJSONL([
            tokenCountLine(timestamp: now, input: 90, cachedInput: 20, output: 10, reasoningOutput: 3)
        ], to: file)

        let parserA = CodexLogParser(
            codexDir: tmpDir,
            checkpointFile: checkpoint,
            accumulatorFile: accumulator,
            fileTotalsFile: totals
        )
        XCTAssertEqual(parserA.aggregateToday().inputTokens, 90)

        let parserB = CodexLogParser(
            codexDir: tmpDir,
            checkpointFile: checkpoint,
            accumulatorFile: accumulator,
            fileTotalsFile: totals
        )
        let afterRestart = parserB.aggregateToday()
        XCTAssertEqual(afterRestart.inputTokens, 90)
        XCTAssertEqual(afterRestart.outputTokens, 13)
        XCTAssertEqual(afterRestart.cacheReadTokens, 20)
    }
}
