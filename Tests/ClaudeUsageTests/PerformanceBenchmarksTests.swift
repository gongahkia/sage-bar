import XCTest
import Foundation
@testable import SageBar

final class PerformanceBenchmarksTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-benchmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
        try super.tearDownWithError()
    }

    func testBenchmarkParserIngestionLargeSyntheticFixture() throws {
        let recordCount = max(10_000, envInt("CLAUDE_USAGE_BENCH_PARSER_RECORDS", defaultValue: 25_000))
        let fixtureURL = tmpDir.appendingPathComponent("claude-large-fixture.jsonl")
        try writeSyntheticClaudeJSONLFixture(to: fixtureURL, records: recordCount)

        let parser = ClaudeCodeLogParser(
            claudeDir: tmpDir,
            checkpointFile: tmpDir.appendingPathComponent("checkpoints.json"),
            accumulatorFile: tmpDir.appendingPathComponent("accumulator.json")
        )

        let options = XCTMeasureOptions()
        options.iterationCount = max(2, envInt("CLAUDE_USAGE_BENCH_ITERATIONS", defaultValue: 3))

        measure(options: options) {
            autoreleasepool {
                let entries = parser.parseFile(fixtureURL)
                XCTAssertEqual(entries.count, recordCount)
            }
        }
    }

    func testBenchmarkCacheAppendThroughputUsingLargeSyntheticFixture() throws {
        let recordCount = max(4_000, envInt("CLAUDE_USAGE_BENCH_CACHE_RECORDS", defaultValue: 8_000))
        let appendCount = max(500, envInt("CLAUDE_USAGE_BENCH_APPENDS", defaultValue: 1_500))

        let fixtureURL = tmpDir.appendingPathComponent("claude-cache-source.jsonl")
        try writeSyntheticClaudeJSONLFixture(to: fixtureURL, records: recordCount)

        let parser = ClaudeCodeLogParser(
            claudeDir: tmpDir,
            checkpointFile: tmpDir.appendingPathComponent("cache-checkpoints.json"),
            accumulatorFile: tmpDir.appendingPathComponent("cache-accumulator.json")
        )
        let entries = parser.parseFile(fixtureURL)
        XCTAssertGreaterThanOrEqual(entries.count, appendCount)

        let accountId = UUID()
        let snapshots = makeSnapshots(
            from: Array(entries.prefix(appendCount)),
            accountId: accountId,
            startDate: Date().addingTimeInterval(-86400) // yesterday, within 30-day retention
        )

        let options = XCTMeasureOptions()
        options.iterationCount = max(2, envInt("CLAUDE_USAGE_BENCH_ITERATIONS", defaultValue: 3))

        measure(options: options) {
            autoreleasepool {
                let iterationDir = tmpDir.appendingPathComponent("cache-iteration-\(UUID().uuidString)")
                do {
                    try FileManager.default.createDirectory(at: iterationDir, withIntermediateDirectories: true)
                } catch {
                    XCTFail("Failed creating cache benchmark directory: \(error)")
                    return
                }
                defer { try? FileManager.default.removeItem(at: iterationDir) }

                let cache = CacheManager(baseURL: iterationDir)
                let queue = DispatchQueue(label: "dev.claudeusage.bench.cache")
                let loaded = queue.sync { () -> [UsageSnapshot] in
                    for snapshot in snapshots {
                        cache.append(snapshot)
                    }
                    return cache.load().filter { $0.accountId == accountId }
                }
                XCTAssertEqual(loaded.count, snapshots.count)
            }
        }
    }

    private func writeSyntheticClaudeJSONLFixture(to url: URL, records: Int) throws {
        let timestamp = "2026-03-01T00:00:00Z"
        var payload = String()
        payload.reserveCapacity(records * 210)

        for i in 0..<records {
            let input = 600 + (i % 200)
            let output = 120 + (i % 60)
            let cacheCreate = 50 + (i % 30)
            let cacheRead = 35 + (i % 20)
            payload += "{\"type\":\"message\",\"timestamp\":\"\(timestamp)\",\"message\":{\"model\":\"claude-3-5-sonnet\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":\(cacheCreate),\"cache_read_input_tokens\":\(cacheRead)}}}\n"
        }

        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSnapshots(from entries: [ClaudeCodeEntry], accountId: UUID, startDate: Date) -> [UsageSnapshot] {
        entries.enumerated().map { index, entry in
            let usage = entry.usage ?? entry.message?.usage
            let input = usage?.input_tokens ?? 0
            let output = usage?.output_tokens ?? 0
            let cacheCreate = usage?.cache_creation_input_tokens ?? 0
            let cacheRead = usage?.cache_read_input_tokens ?? 0
            let cost = (Double((index % 50) + 1) * 0.001)
            return UsageSnapshot(
                accountId: accountId,
                timestamp: startDate.addingTimeInterval(Double(index)),
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheCreate,
                cacheReadTokens: cacheRead,
                totalCostUSD: cost,
                modelBreakdown: [
                    ModelUsage(
                        modelId: "claude-sonnet-4-6",
                        inputTokens: input,
                        outputTokens: output,
                        cacheTokens: cacheCreate + cacheRead,
                        costUSD: cost
                    )
                ],
                costConfidence: .billingGrade
            )
        }
    }

    private func envInt(_ key: String, defaultValue: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let parsed = Int(raw),
              parsed > 0 else {
            return defaultValue
        }
        return parsed
    }
}
