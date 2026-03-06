import XCTest
@testable import SageBar

final class ClaudeCodeLogParserTests: XCTestCase {
    private let parser = ClaudeCodeLogParser.shared
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

    private func writeJSONL(_ content: String) -> URL {
        let url = tmpDir.appendingPathComponent("test.jsonl")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParseFileValidJSONL() {
        let jsonl = """
        {"type":"message","message":{"model":"claude-3-5-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"message","usage":{"input_tokens":200,"output_tokens":80}}
        """
        let url = writeJSONL(jsonl)
        let entries = parser.parseFile(url)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].message?.usage?.input_tokens, 100)
        XCTAssertEqual(entries[1].usage?.input_tokens, 200)
    }

    func testParseFileMalformedLinesSkipped() {
        let jsonl = """
        {"type":"message","usage":{"input_tokens":10,"output_tokens":5}}
        this is not json
        {"type":"message","usage":{"input_tokens":20,"output_tokens":8}}
        """
        let url = writeJSONL(jsonl)
        let entries = parser.parseFile(url)
        XCTAssertEqual(entries.count, 2, "malformed line should be skipped")
    }

    func testParseFileNonExistentReturnsEmpty() {
        let nonExistent = tmpDir.appendingPathComponent("missing.jsonl")
        let entries = parser.parseFile(nonExistent)
        XCTAssertTrue(entries.isEmpty)
    }

    func testAggregateTodayEmptyDirectoryReturnsZeroCounts() {
        // aggregateToday scans ~/.claude/projects; if no files match today, returns zeros
        let snap = parser.aggregateToday()
        // we only verify structure — actual counts depend on real usage
        XCTAssertGreaterThanOrEqual(snap.inputTokens, 0)
        XCTAssertGreaterThanOrEqual(snap.outputTokens, 0)
        XCTAssertEqual(snap.totalCostUSD, 0.0)
    }

    func testParseFileEmptyFileReturnsEmpty() {
        let url = writeJSONL("")
        XCTAssertTrue(parser.parseFile(url).isEmpty)
    }

    // MARK: - aggregatePeriod

    func testAggregatePeriodReturnsOnlyWithinWindow() {
        // aggregatePeriod reads real ~/.claude/projects; result should not include dates outside window
        let snaps = parser.aggregatePeriod(days: 7)
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        for s in snaps {
            XCTAssertGreaterThanOrEqual(s.timestamp, cutoff)
        }
    }

    func testAggregatePeriodSortedAscending() {
        let snaps = parser.aggregatePeriod(days: 30)
        for i in 1..<snaps.count {
            XCTAssertLessThanOrEqual(snaps[i-1].timestamp, snaps[i].timestamp)
        }
    }

    func testAggregatePeriodNonNegativeTokens() {
        for snap in parser.aggregatePeriod(days: 30) {
            XCTAssertGreaterThanOrEqual(snap.inputTokens, 0)
            XCTAssertGreaterThanOrEqual(snap.outputTokens, 0)
        }
    }

    // MARK: - size cap

    func testOversizedJSONLSkippedAndErrorLogged() throws {
        let url = tmpDir.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        handle.truncateFile(atOffset: 50 * 1024 * 1024 + 1) // sparse file, no real data
        handle.closeFile()
        let entries = parser.parseFile(url)
        XCTAssertTrue(entries.isEmpty, "oversized file should return empty array")
        let exp = expectation(description: "ErrorLogger sets lastError")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertNotNil(ErrorLogger.shared.lastError, "ErrorLogger should have received oversized-file warning")
    }

    // MARK: - FSEvent watcher

    func testFallbackTimerTriggersRescan() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let jsonl = projectsDir.appendingPathComponent("session.jsonl")
        try "{\"type\":\"message\",\"usage\":{\"input_tokens\":42,\"output_tokens\":7}}\n"
            .write(to: jsonl, atomically: true, encoding: .utf8)
        // 1s fallback interval so test completes within 3s; no FSEvent fired = timer drives the notification
        let localParser = ClaudeCodeLogParser(claudeDir: tmpDir, fallbackInterval: 1)
        let exp = expectation(description: "fallback timer fires .claudeCodeLogsChanged within 3s")
        exp.assertForOverFulfill = false
        let obs = NotificationCenter.default.addObserver(
            forName: .claudeCodeLogsChanged, object: nil, queue: .main) { _ in exp.fulfill() }
        defer { NotificationCenter.default.removeObserver(obs); localParser.stopWatching() }
        localParser.startWatching()
        wait(for: [exp], timeout: 3)
        XCTAssertGreaterThanOrEqual(localParser.aggregateToday().inputTokens, 0) // no crash after rescan
    }

    func testFSEventFiresForNestedJSONL() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        let subDir = projectsDir.appendingPathComponent("subproject")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let localParser = ClaudeCodeLogParser(claudeDir: tmpDir)
        let exp = expectation(description: "claudeCodeLogsChanged fires for nested .jsonl write")
        let obs = NotificationCenter.default.addObserver(
            forName: .claudeCodeLogsChanged, object: nil, queue: .main) { _ in exp.fulfill() }
        defer { NotificationCenter.default.removeObserver(obs) }
        localParser.startWatching()
        defer { localParser.stopWatching() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let file = subDir.appendingPathComponent("session.jsonl")
            try? "{\"type\":\"message\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}\n"
                .write(to: file, atomically: true, encoding: .utf8)
        }
        wait(for: [exp], timeout: 5)
    }

    func testAggregateTodayUsesEntryTimestampOverFileModificationDate() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let file = projectsDir.appendingPathComponent("session.jsonl")
        let now = Date()
        let nowISO = ISO8601DateFormatter().string(from: now)
        try """
        {"type":"message","timestamp":"\(nowISO)","usage":{"input_tokens":9,"output_tokens":4}}
        """.write(to: file, atomically: true, encoding: .utf8)
        let oldMod = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        try FileManager.default.setAttributes([.modificationDate: oldMod], ofItemAtPath: file.path)

        let localParser = ClaudeCodeLogParser(claudeDir: tmpDir)
        let snap = localParser.aggregateToday()
        XCTAssertEqual(snap.inputTokens, 9)
        XCTAssertEqual(snap.outputTokens, 4)
    }

    func testAggregatePeriodUsesEntryTimestampNotFileModificationDate() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let file = projectsDir.appendingPathComponent("session.jsonl")
        let oldEvent = Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? Date()
        let oldISO = ISO8601DateFormatter().string(from: oldEvent)
        try """
        {"type":"message","timestamp":"\(oldISO)","usage":{"input_tokens":20,"output_tokens":8}}
        """.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)

        let localParser = ClaudeCodeLogParser(claudeDir: tmpDir)
        let snaps = localParser.aggregatePeriod(days: 1)
        XCTAssertTrue(snaps.isEmpty, "old event timestamp must be excluded even if file mtime is recent")
    }

    func testParseFileIncrementalUsesPerFileCheckpoint() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let file = projectsDir.appendingPathComponent("session.jsonl")
        try """
        {"type":"message","timestamp":"2026-02-28T00:00:00Z","usage":{"input_tokens":1,"output_tokens":1}}
        """.write(to: file, atomically: true, encoding: .utf8)
        let localParser = ClaudeCodeLogParser(claudeDir: tmpDir)

        let first = localParser.parseFile(file, incremental: true)
        XCTAssertEqual(first.count, 1)
        let second = localParser.parseFile(file, incremental: true)
        XCTAssertEqual(second.count, 0)

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("""
        {"type":"message","timestamp":"2026-02-28T00:01:00Z","usage":{"input_tokens":2,"output_tokens":2}}
        """.utf8))
        try handle.close()

        let third = localParser.parseFile(file, incremental: true)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third.first?.usage?.input_tokens, 2)
    }

    func testCheckpointPersistenceAcrossParserRestart() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let file = projectsDir.appendingPathComponent("session.jsonl")
        try """
        {"type":"message","timestamp":"2026-02-28T00:00:00Z","usage":{"input_tokens":3,"output_tokens":1}}
        """.write(to: file, atomically: true, encoding: .utf8)
        let checkpoint = tmpDir.appendingPathComponent("checkpoints.json")

        let parserA = ClaudeCodeLogParser(claudeDir: tmpDir, checkpointFile: checkpoint)
        XCTAssertEqual(parserA.parseFile(file, incremental: true).count, 1)

        let parserB = ClaudeCodeLogParser(claudeDir: tmpDir, checkpointFile: checkpoint)
        XCTAssertEqual(parserB.parseFile(file, incremental: true).count, 0)
    }

    func testAggregateTodayIncrementalAccumulatorDeterministicAcrossPolls() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let file = projectsDir.appendingPathComponent("session.jsonl")
        let checkpoint = tmpDir.appendingPathComponent("checkpoints.json")
        let accFile = tmpDir.appendingPathComponent("accumulator.json")
        let parser = ClaudeCodeLogParser(claudeDir: tmpDir, checkpointFile: checkpoint, accumulatorFile: accFile)

        try """
        {"type":"message","timestamp":"\(ISO8601DateFormatter().string(from: Date()))","usage":{"input_tokens":2,"output_tokens":1}}
        """.write(to: file, atomically: true, encoding: .utf8)
        let first = parser.aggregateToday()
        XCTAssertEqual(first.inputTokens, 2)
        XCTAssertEqual(first.outputTokens, 1)

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("""
        {"type":"message","timestamp":"\(ISO8601DateFormatter().string(from: Date()))","usage":{"input_tokens":3,"output_tokens":2}}
        """.utf8))
        try handle.close()

        let second = parser.aggregateToday()
        XCTAssertEqual(second.inputTokens, 5)
        XCTAssertEqual(second.outputTokens, 3)

        let third = parser.aggregateToday()
        XCTAssertEqual(third.inputTokens, 5, "unchanged files must not be re-ingested")
        XCTAssertEqual(third.outputTokens, 3)
    }

    func testAggregateTodayAccumulatorSurvivesRestart() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let file = projectsDir.appendingPathComponent("session.jsonl")
        let checkpoint = tmpDir.appendingPathComponent("checkpoints.json")
        let accFile = tmpDir.appendingPathComponent("accumulator.json")
        let now = ISO8601DateFormatter().string(from: Date())
        try """
        {"type":"message","timestamp":"\(now)","usage":{"input_tokens":4,"output_tokens":2}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let parserA = ClaudeCodeLogParser(claudeDir: tmpDir, checkpointFile: checkpoint, accumulatorFile: accFile)
        XCTAssertEqual(parserA.aggregateToday().inputTokens, 4)

        let parserB = ClaudeCodeLogParser(claudeDir: tmpDir, checkpointFile: checkpoint, accumulatorFile: accFile)
        XCTAssertEqual(parserB.aggregateToday().inputTokens, 4, "persisted accumulator must keep deterministic totals across restarts")
    }

    func testAggregateTodayOnlyProcessesChangedFilesIncrementally() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let fileA = projectsDir.appendingPathComponent("session-a.jsonl")
        let fileB = projectsDir.appendingPathComponent("session-b.jsonl")
        let checkpoint = tmpDir.appendingPathComponent("checkpoints.json")
        let accFile = tmpDir.appendingPathComponent("accumulator.json")
        let nowISO = ISO8601DateFormatter().string(from: Date())

        try """
        {"type":"message","timestamp":"\(nowISO)","usage":{"input_tokens":2,"output_tokens":1}}
        """.write(to: fileA, atomically: true, encoding: .utf8)
        try """
        {"type":"message","timestamp":"\(nowISO)","usage":{"input_tokens":3,"output_tokens":2}}
        """.write(to: fileB, atomically: true, encoding: .utf8)

        let parser = ClaudeCodeLogParser(claudeDir: tmpDir, checkpointFile: checkpoint, accumulatorFile: accFile)
        let first = parser.aggregateToday()
        XCTAssertEqual(first.inputTokens, 5)
        XCTAssertEqual(first.outputTokens, 3)

        let second = parser.aggregateToday()
        XCTAssertEqual(second.inputTokens, 5, "unchanged files must not be re-read")
        XCTAssertEqual(second.outputTokens, 3)

        let handle = try FileHandle(forWritingTo: fileA)
        handle.seekToEndOfFile()
        handle.write(Data("""
        {"type":"message","timestamp":"\(nowISO)","usage":{"input_tokens":7,"output_tokens":4}}
        """.utf8))
        try handle.close()

        let third = parser.aggregateToday()
        XCTAssertEqual(third.inputTokens, 12, "only newly appended lines from changed file should be added")
        XCTAssertEqual(third.outputTokens, 7)
    }
}
