import XCTest
import Foundation
import Darwin
@testable import SageBar

final class MemoryBudgetRegressionTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-memory-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
        try super.tearDownWithError()
    }

    func testParserFlowRespectsConfigurableMemoryBudget() throws {
        let records = max(8_000, envInt("CLAUDE_USAGE_MEMORY_PARSER_RECORDS", defaultValue: 20_000))
        let memoryBudgetMB = memoryBudgetMB(overrideKey: "CLAUDE_USAGE_PARSER_MEMORY_BUDGET_MB", defaultMB: 320)
        let fixtureURL = tmpDir.appendingPathComponent("parser-memory-fixture.jsonl")
        try writeSyntheticClaudeJSONLFixture(to: fixtureURL, records: records)

        let parser = ClaudeCodeLogParser(
            claudeDir: tmpDir,
            checkpointFile: tmpDir.appendingPathComponent("parser-checkpoints.json"),
            accumulatorFile: tmpDir.appendingPathComponent("parser-accumulator.json")
        )

        var parsedCount = 0
        let peakDeltaBytes = measurePeakResidentDeltaBytes {
            let entries = parser.parseFile(fixtureURL)
            parsedCount = entries.count
        }

        XCTAssertEqual(parsedCount, records)
        assertMemoryBudget(
            usedBytes: peakDeltaBytes,
            budgetMB: memoryBudgetMB,
            label: "Parser flow"
        )
    }

    func testCacheFlowRespectsConfigurableMemoryBudget() throws {
        let records = max(4_000, envInt("CLAUDE_USAGE_MEMORY_CACHE_RECORDS", defaultValue: 10_000))
        let appendCount = max(500, envInt("CLAUDE_USAGE_MEMORY_CACHE_APPENDS", defaultValue: 1_800))
        let memoryBudgetMB = memoryBudgetMB(overrideKey: "CLAUDE_USAGE_CACHE_MEMORY_BUDGET_MB", defaultMB: 320)

        let fixtureURL = tmpDir.appendingPathComponent("cache-memory-fixture.jsonl")
        try writeSyntheticClaudeJSONLFixture(to: fixtureURL, records: records)

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

        let cacheDir = tmpDir.appendingPathComponent("cache-under-test")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cache = CacheManager(baseURL: cacheDir)

        var loadedCount = 0
        let peakDeltaBytes = measurePeakResidentDeltaBytes {
            for snapshot in snapshots {
                cache.append(snapshot)
            }
            loadedCount = cache.load().filter { $0.accountId == accountId }.count
        }

        XCTAssertEqual(loadedCount, snapshots.count)
        assertMemoryBudget(
            usedBytes: peakDeltaBytes,
            budgetMB: memoryBudgetMB,
            label: "Cache append flow"
        )
    }

    private func measurePeakResidentDeltaBytes(operation: @escaping () -> Void) -> UInt64 {
        let baseline = residentMemoryBytes()
        var peak = baseline

        let group = DispatchGroup()
        group.enter()
        let queue = DispatchQueue(label: "dev.claudeusage.memory.budget", qos: .userInitiated)
        queue.async {
            operation()
            group.leave()
        }

        while group.wait(timeout: .now()) == .timedOut {
            peak = max(peak, residentMemoryBytes())
            usleep(2_000)
        }
        peak = max(peak, residentMemoryBytes())

        if peak <= baseline {
            return 0
        }
        return peak - baseline
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }
        return UInt64(info.resident_size)
    }

    private func assertMemoryBudget(usedBytes: UInt64, budgetMB: Int, label: String) {
        let budgetBytes = UInt64(max(1, budgetMB)) * 1_048_576
        XCTAssertLessThanOrEqual(
            usedBytes,
            budgetBytes,
            "\(label) exceeded memory budget: used \(formatMiB(usedBytes)) MiB, budget \(budgetMB) MiB"
        )
    }

    private func formatMiB(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576.0)
    }

    private func memoryBudgetMB(overrideKey: String, defaultMB: Int) -> Int {
        let globalBudget = envInt("CLAUDE_USAGE_MEMORY_BUDGET_MB", defaultValue: defaultMB)
        return envInt(overrideKey, defaultValue: globalBudget)
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
