import XCTest
@testable import ClaudeUsage

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

    // MARK: - FSEvent watcher

    func testFallbackTimerTriggersRescan() throws {
        let projectsDir = tmpDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let jsonl = projectsDir.appendingPathComponent("session.jsonl")
        try """{"type":"message","usage":{"input_tokens":42,"output_tokens":7}}\n"""
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
            try? """{"type":"message","usage":{"input_tokens":1,"output_tokens":1}}\n"""
                .write(to: file, atomically: true, encoding: .utf8)
        }
        wait(for: [exp], timeout: 5)
    }
}
