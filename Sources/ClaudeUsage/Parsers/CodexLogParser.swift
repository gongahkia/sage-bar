import Foundation
import CoreServices

// MARK: - JSONL schema types

struct CodexSessionEntry: Codable {
    var timestamp: String?
    var type: String
    var payload: CodexEventPayload?
}

struct CodexEventPayload: Codable {
    var type: String?
    var info: CodexTokenCountInfo?
}

struct CodexTokenCountInfo: Codable {
    var total_token_usage: CodexTokenUsage?
}

struct CodexTokenUsage: Codable {
    var input_tokens: Int?
    var cached_input_tokens: Int?
    var output_tokens: Int?
    var reasoning_output_tokens: Int?
}

// MARK: - Parser

class CodexLogParser {
    private struct DailyAccumulator {
        var day: DateComponents
        var input: Int
        var output: Int
        var cacheRead: Int
    }

    private struct PersistedDailyAccumulator: Codable {
        var year: Int
        var month: Int
        var day: Int
        var input: Int
        var output: Int
        var cacheRead: Int

        init(from acc: DailyAccumulator) {
            self.year = acc.day.year ?? 0
            self.month = acc.day.month ?? 0
            self.day = acc.day.day ?? 0
            self.input = acc.input
            self.output = acc.output
            self.cacheRead = acc.cacheRead
        }

        var asAccumulator: DailyAccumulator {
            DailyAccumulator(
                day: DateComponents(year: year, month: month, day: day),
                input: input,
                output: output,
                cacheRead: cacheRead
            )
        }
    }

    private struct TokenTotals: Codable {
        var input: Int
        var cachedInput: Int
        var output: Int
        var reasoningOutput: Int

        static let zero = TokenTotals(input: 0, cachedInput: 0, output: 0, reasoningOutput: 0)

        init(_ usage: CodexTokenUsage) {
            self.input = max(0, usage.input_tokens ?? 0)
            self.cachedInput = max(0, usage.cached_input_tokens ?? 0)
            self.output = max(0, usage.output_tokens ?? 0)
            self.reasoningOutput = max(0, usage.reasoning_output_tokens ?? 0)
        }

        init(input: Int, cachedInput: Int, output: Int, reasoningOutput: Int) {
            self.input = input
            self.cachedInput = cachedInput
            self.output = output
            self.reasoningOutput = reasoningOutput
        }

        func delta(from previous: TokenTotals) -> TokenTotals {
            // token_count is cumulative per session; if counters decrease, treat as a session reset.
            if input < previous.input ||
                cachedInput < previous.cachedInput ||
                output < previous.output ||
                reasoningOutput < previous.reasoningOutput {
                return self
            }
            return TokenTotals(
                input: input - previous.input,
                cachedInput: cachedInput - previous.cachedInput,
                output: output - previous.output,
                reasoningOutput: reasoningOutput - previous.reasoningOutput
            )
        }
    }

    static let shared = CodexLogParser()
    private let codexDir: URL
    private let fallbackInterval: TimeInterval
    private var fileChecksums: [URL: (Date, Int, UInt64?)] = [:] // mtime+size+inode cache for skip-unchanged
    private var fsEventStream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var lastFSEventDate: Date?

    private let checkpointFile: URL
    private let accumulatorFile: URL
    private let fileTotalsFile: URL
    private var lineCheckpoints: [URL: Int]
    private var dailyAccumulator: DailyAccumulator?
    private var fileTotalsByURL: [URL: TokenTotals]
    private var decodeFailuresByFile: [URL: Int] = [:]
    private let quarantineFailureThreshold = 20

    private let isoTimestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let isoTimestampNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {
        self.codexDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        self.fallbackInterval = 60
        let base = AppConstants.sharedContainerURL
        self.checkpointFile = base.appendingPathComponent("codex_checkpoints.json")
        self.accumulatorFile = base.appendingPathComponent("codex_daily_accumulator.json")
        self.fileTotalsFile = base.appendingPathComponent("codex_file_totals.json")
        self.lineCheckpoints = Self.loadLineCheckpoints(from: self.checkpointFile)
        self.dailyAccumulator = Self.loadDailyAccumulator(from: self.accumulatorFile)
        self.fileTotalsByURL = Self.loadFileTotals(from: self.fileTotalsFile)
    }

    internal init(
        codexDir: URL,
        fallbackInterval: TimeInterval = 60,
        checkpointFile: URL? = nil,
        accumulatorFile: URL? = nil,
        fileTotalsFile: URL? = nil
    ) {
        self.codexDir = codexDir
        self.fallbackInterval = fallbackInterval
        self.checkpointFile = checkpointFile ?? codexDir.appendingPathComponent("codex_checkpoints.json")
        self.accumulatorFile = accumulatorFile ?? codexDir.appendingPathComponent("codex_daily_accumulator.json")
        self.fileTotalsFile = fileTotalsFile ?? codexDir.appendingPathComponent("codex_file_totals.json")
        self.lineCheckpoints = Self.loadLineCheckpoints(from: self.checkpointFile)
        self.dailyAccumulator = Self.loadDailyAccumulator(from: self.accumulatorFile)
        self.fileTotalsByURL = Self.loadFileTotals(from: self.fileTotalsFile)
    }

    private var missingDirLogged = false

    func discoverSessionFiles() -> [URL] {
        let sessionsDir = codexDir.appendingPathComponent("sessions")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsDir.path, isDirectory: &isDir), isDir.boolValue else {
            if !missingDirLogged {
                ErrorLogger.shared.log("Codex session directory not found at \(sessionsDir.path)", level: "WARN")
                missingDirLogged = true
            }
            return []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    func parseFile(_ url: URL, incremental: Bool = false) -> [CodexSessionEntry] {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 100 * 1024 * 1024 {
            ErrorLogger.shared.log("Skipping oversized Codex log file \(url.lastPathComponent) (\(size / 1024 / 1024)MB)", level: "WARN")
            return []
        }
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            ErrorLogger.shared.log("Cannot read Codex log file at \(url.path): \(error.localizedDescription)")
            return []
        }
        defer { try? fileHandle.close() }
        let dec = JSONDecoder()
        var allResults: [CodexSessionEntry] = []
        var incrementalResults: [CodexSessionEntry] = []
        var rejectedCount = 0
        var totalLines = 0
        var bytesRead = 0
        let startIndex = incremental ? (lineCheckpoints[url] ?? 0) : 0
        var lineBuffer: [UInt8] = []

        func processLine(_ bytes: [UInt8]) -> Bool {
            let raw = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return true }
            totalLines += 1
            do {
                let entry = try dec.decode(CodexSessionEntry.self, from: Data(raw.utf8))
                allResults.append(entry)
                if !incremental || totalLines > startIndex {
                    incrementalResults.append(entry)
                }
            } catch {
                rejectedCount += 1
                let preview = String(raw.prefix(200))
                ErrorLogger.shared.log("Malformed Codex JSONL line \(totalLines) in \(url.lastPathComponent): \(preview)", level: "WARN")
                if recordDecodeFailureAndMaybeQuarantine(for: url) {
                    return false
                }
            }
            return true
        }

        if incremental {
            lineCheckpoints[url] = max(0, startIndex)
        }

        parseLoop: while true {
            let chunk: Data
            do {
                chunk = try fileHandle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                ErrorLogger.shared.log("Failed streaming read for \(url.lastPathComponent): \(error.localizedDescription)", level: "WARN")
                break
            }
            if chunk.isEmpty { break }
            bytesRead += chunk.count
            for byte in chunk {
                if byte == 0x0A { // "\n"
                    if !processLine(lineBuffer) {
                        break parseLoop
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                    continue
                }
                lineBuffer.append(byte)
            }
        }

        if !lineBuffer.isEmpty {
            _ = processLine(lineBuffer)
        }

        var results = incremental ? incrementalResults : allResults
        if incremental {
            let prev = startIndex
            if prev > totalLines {
                ErrorLogger.shared.log(
                    "Codex checkpoint exceeds current line count for \(url.lastPathComponent); resetting checkpoint and token totals (file truncated or rotated)",
                    level: "WARN"
                )
                lineCheckpoints[url] = totalLines
                fileTotalsByURL[url] = .zero
                persistLineCheckpoints()
                persistFileTotals()
                results = allResults
            } else {
                lineCheckpoints[url] = totalLines
            }
            persistLineCheckpoints()
        }
        ParserMetricsStore.shared.record(
            parser: "codex",
            filesScanned: 1,
            linesParsed: results.count,
            linesRejected: rejectedCount,
            bytesRead: bytesRead
        )
        return results
    }

    private func recordDecodeFailureAndMaybeQuarantine(for url: URL) -> Bool {
        let nextCount = (decodeFailuresByFile[url] ?? 0) + 1
        decodeFailuresByFile[url] = nextCount
        guard nextCount >= quarantineFailureThreshold else { return false }
        decodeFailuresByFile[url] = 0
        let quarantineDir = codexDir.appendingPathComponent("quarantine")
        try? FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        let destination = quarantineDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            lineCheckpoints.removeValue(forKey: url)
            fileTotalsByURL.removeValue(forKey: url)
            fileChecksums.removeValue(forKey: url)
            persistLineCheckpoints()
            persistFileTotals()
            ErrorLogger.shared.log("Quarantined corrupt Codex log file \(url.lastPathComponent) after repeated decode failures", level: "WARN")
            return true
        } catch {
            ErrorLogger.shared.log("Failed to quarantine corrupt Codex log file \(url.lastPathComponent): \(error.localizedDescription)", level: "WARN")
            return false
        }
    }

    func aggregateToday() -> UsageSnapshot {
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.year, .month, .day], from: Date())
        if dailyAccumulator?.day != todayComps {
            dailyAccumulator = DailyAccumulator(day: todayComps, input: 0, output: 0, cacheRead: 0)
            persistDailyAccumulator()
        }
        for url in discoverSessionFiles() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mod = attrs?[.modificationDate] as? Date
            let size = (attrs?[.size] as? Int) ?? -1
            let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
            guard let mod else { continue }
            if let prev = fileChecksums[url], prev.0 == mod, prev.1 == size, prev.2 == inode { continue }
            fileChecksums[url] = (mod, size, inode)
            ingest(entries: parseFile(url, incremental: true), file: url, fallbackDate: mod, todayComps: todayComps)
        }
        persistDailyAccumulator()
        persistFileTotals()
        let acc = dailyAccumulator ?? DailyAccumulator(day: todayComps, input: 0, output: 0, cacheRead: 0)
        return UsageSnapshot(
            accountId: UUID(), // overridden by caller with real account id
            timestamp: Date(),
            inputTokens: acc.input,
            outputTokens: acc.output,
            cacheCreationTokens: 0,
            cacheReadTokens: acc.cacheRead,
            totalCostUSD: 0,
            modelBreakdown: [
                ModelUsage(
                    modelId: "codex-local",
                    inputTokens: acc.input,
                    outputTokens: acc.output,
                    cacheTokens: acc.cacheRead,
                    costUSD: 0
                )
            ],
            costConfidence: .estimated
        )
    }

    func aggregatePeriod(days: Int) -> [UsageSnapshot] {
        let cal = Calendar.current
        var dayMap: [DateComponents: (Int, Int, Int)] = [:] // input, output, cacheRead
        for url in discoverSessionFiles() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mod = attrs?[.modificationDate] as? Date
            var running = TokenTotals.zero
            for entry in parseFile(url) {
                guard let currentTotals = tokenTotals(from: entry) else { continue }
                let delta = currentTotals.delta(from: running)
                running = currentTotals
                guard let eventDate = entryTimestamp(entry, fallback: mod) else { continue }
                let comps = cal.dateComponents([.year, .month, .day], from: eventDate)
                let prev = dayMap[comps] ?? (0, 0, 0)
                dayMap[comps] = (
                    prev.0 + delta.input,
                    prev.1 + delta.output + delta.reasoningOutput,
                    prev.2 + delta.cachedInput
                )
            }
        }
        let cutoff = cal.date(byAdding: .day, value: -days, to: Date())!
        return dayMap.compactMap { (comps, vals) -> UsageSnapshot? in
            guard let date = cal.date(from: comps), date >= cutoff else { return nil }
            return UsageSnapshot(
                accountId: UUID(),
                timestamp: date,
                inputTokens: vals.0,
                outputTokens: vals.1,
                cacheCreationTokens: 0,
                cacheReadTokens: vals.2,
                totalCostUSD: 0,
                modelBreakdown: [],
                costConfidence: .estimated
            )
        }.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - FSEvents watcher

    func startWatching() {
        stopWatching()
        let sessionsDir = codexDir.appendingPathComponent("sessions")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        let paths = [sessionsDir.path] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let p = info else { return }
            Unmanaged<CodexLogParser>.fromOpaque(p).takeUnretainedValue().debounceLogsChanged()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil, cb, &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.0, flags
        ) else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsEventStream = stream
        lastFSEventDate = nil
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: fallbackInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let last = self.lastFSEventDate ?? .distantPast
            if Date().timeIntervalSince(last) >= 60 {
                self.debounceLogsChanged()
            }
        }
    }

    func stopWatching() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        guard let s = fsEventStream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        fsEventStream = nil
    }

    private func debounceLogsChanged() { // 500ms debounce
        lastFSEventDate = Date()
        debounceWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .codexLogsChanged, object: nil)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - internals

    private func ingest(entries: [CodexSessionEntry], file: URL, fallbackDate: Date?, todayComps: DateComponents) {
        guard !entries.isEmpty else { return }
        let cal = Calendar.current
        var running = fileTotalsByURL[file] ?? .zero
        for entry in entries {
            guard let totals = tokenTotals(from: entry) else { continue }
            let delta = totals.delta(from: running)
            running = totals
            guard let eventDate = entryTimestamp(entry, fallback: fallbackDate) else { continue }
            if cal.dateComponents([.year, .month, .day], from: eventDate) == todayComps {
                dailyAccumulator?.input += delta.input
                dailyAccumulator?.output += delta.output + delta.reasoningOutput
                dailyAccumulator?.cacheRead += delta.cachedInput
            }
        }
        fileTotalsByURL[file] = running
    }

    private func tokenTotals(from entry: CodexSessionEntry) -> TokenTotals? {
        guard entry.type == "event_msg" else { return nil }
        guard entry.payload?.type == "token_count" else { return nil }
        guard let usage = entry.payload?.info?.total_token_usage else { return nil }
        return TokenTotals(usage)
    }

    private func entryTimestamp(_ entry: CodexSessionEntry, fallback: Date?) -> Date? {
        guard let raw = entry.timestamp else { return fallback }
        return isoTimestamp.date(from: raw) ?? isoTimestampNoFraction.date(from: raw) ?? fallback
    }

    private static func loadLineCheckpoints(from file: URL) -> [URL: Int] {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        var mapped: [URL: Int] = [:]
        for (path, line) in raw {
            mapped[URL(fileURLWithPath: path)] = line
        }
        return mapped
    }

    private static func loadDailyAccumulator(from file: URL) -> DailyAccumulator? {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode(PersistedDailyAccumulator.self, from: data) else { return nil }
        return raw.asAccumulator
    }

    private static func loadFileTotals(from file: URL) -> [URL: TokenTotals] {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode([String: TokenTotals].self, from: data) else { return [:] }
        var mapped: [URL: TokenTotals] = [:]
        for (path, totals) in raw {
            mapped[URL(fileURLWithPath: path)] = totals
        }
        return mapped
    }

    private func persistLineCheckpoints() {
        let raw = Dictionary(uniqueKeysWithValues: lineCheckpoints.map { ($0.key.path, $0.value) })
        do {
            let data = try JSONEncoder().encode(raw)
            try data.write(to: checkpointFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Failed to persist Codex checkpoints: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func persistDailyAccumulator() {
        guard let dailyAccumulator else { return }
        do {
            let data = try JSONEncoder().encode(PersistedDailyAccumulator(from: dailyAccumulator))
            try data.write(to: accumulatorFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Failed to persist Codex daily accumulator: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func persistFileTotals() {
        let raw = Dictionary(uniqueKeysWithValues: fileTotalsByURL.map { ($0.key.path, $0.value) })
        do {
            let data = try JSONEncoder().encode(raw)
            try data.write(to: fileTotalsFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Failed to persist Codex file totals: \(error.localizedDescription)", level: "WARN")
        }
    }
}

extension Notification.Name {
    static let codexLogsChanged = Notification.Name("CodexLogsChanged")
}
