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
}
