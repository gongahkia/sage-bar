import Foundation
import OSLog
import CoreServices

private let log = Logger(subsystem: "dev.claudeusage", category: "LogParser")

// MARK: – JSONL schema types

struct ClaudeCodeEntry: Codable {
    var type: String
    var message: ClaudeMessage?
    var usage: ClaudeUsageField?
    var timestamp: String?
    var created_at: String?
    var time: String?
}

struct ClaudeMessage: Codable {
    var model: String?
    var usage: ClaudeUsageField?
}

struct ClaudeUsageField: Codable {
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_creation_input_tokens: Int?
    var cache_read_input_tokens: Int?
}

// MARK: – Parser

class ClaudeCodeLogParser {
    private struct DailyAccumulator {
        var day: DateComponents
        var input: Int
        var output: Int
        var cacheCreate: Int
        var cacheRead: Int
    }

    private struct PersistedDailyAccumulator: Codable {
        var year: Int
        var month: Int
        var day: Int
        var input: Int
        var output: Int
        var cacheCreate: Int
        var cacheRead: Int

        init(from acc: DailyAccumulator) {
            self.year = acc.day.year ?? 0
            self.month = acc.day.month ?? 0
            self.day = acc.day.day ?? 0
            self.input = acc.input
            self.output = acc.output
            self.cacheCreate = acc.cacheCreate
            self.cacheRead = acc.cacheRead
        }

        var asAccumulator: DailyAccumulator {
            DailyAccumulator(
                day: DateComponents(year: year, month: month, day: day),
                input: input,
                output: output,
                cacheCreate: cacheCreate,
                cacheRead: cacheRead
            )
        }
    }

    static let shared = ClaudeCodeLogParser()
    private let claudeDir: URL
    let fallbackInterval: TimeInterval // internal for test override
    private var fileChecksums: [URL: (Date, Int, UInt64?)] = [:] // mtime+size+inode cache for skip-unchanged
    private var fsEventStream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var lastFSEventDate: Date?
    private let checkpointFile: URL
    private let accumulatorFile: URL
    private var lineCheckpoints: [URL: Int]
    private var dailyAccumulator: DailyAccumulator?
    private var lineCheckpointsDirty = false
    private var dailyAccumulatorDirty = false
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
        self.claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        self.fallbackInterval = 60
        let base = AppConstants.sharedContainerURL
        self.checkpointFile = base.appendingPathComponent("claude_code_checkpoints.json")
        self.accumulatorFile = base.appendingPathComponent("claude_code_daily_accumulator.json")
        self.lineCheckpoints = Self.loadLineCheckpoints(from: self.checkpointFile)
        self.dailyAccumulator = Self.loadDailyAccumulator(from: self.accumulatorFile)
    }

    internal init(
        claudeDir: URL,
        fallbackInterval: TimeInterval = 60,
        checkpointFile: URL? = nil,
        accumulatorFile: URL? = nil
    ) {
        self.claudeDir = claudeDir
        self.fallbackInterval = fallbackInterval
        self.checkpointFile = checkpointFile ?? claudeDir.appendingPathComponent("claude_code_checkpoints.json")
        self.accumulatorFile = accumulatorFile ?? claudeDir.appendingPathComponent("claude_code_daily_accumulator.json")
        self.lineCheckpoints = Self.loadLineCheckpoints(from: self.checkpointFile)
        self.dailyAccumulator = Self.loadDailyAccumulator(from: self.accumulatorFile)
    }

    private var missingDirLogged = false
    func discoverSessionFiles() -> [URL] {
        let projectsDir = claudeDir.appendingPathComponent("projects")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsDir.path, isDirectory: &isDir), isDir.boolValue else {
            if !missingDirLogged {
                ErrorLogger.shared.log("Claude Code log directory not found at \(projectsDir.path)", level: "WARN")
                missingDirLogged = true
            }
            return []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    func parseFile(_ url: URL, incremental: Bool = false, deferPersistence: Bool = false) -> [ClaudeCodeEntry] {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 50 * 1024 * 1024 {
            ErrorLogger.shared.log("Skipping oversized log file \(url.lastPathComponent) (\(size / 1024 / 1024)MB)", level: "WARN")
            return []
        }
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            ErrorLogger.shared.log("Cannot read log file at \(url.path): \(error.localizedDescription)")
            return []
        }
        defer { try? fileHandle.close() }
        let dec = JSONDecoder()
        var allResults: [ClaudeCodeEntry] = []
        var incrementalResults: [ClaudeCodeEntry] = []
        var rejectedCount = 0
        var totalRecords = 0
        var bytesRead = 0
        let startIndex = incremental ? (lineCheckpoints[url] ?? 0) : 0
        var recordBuffer: [UInt8] = []
        var inString = false
        var escaping = false
        var braceDepth = 0

        func processRecord(_ bytes: [UInt8]) -> Bool {
            let raw = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return true }
            totalRecords += 1
            do {
                let entry = try dec.decode(ClaudeCodeEntry.self, from: Data(raw.utf8))
                allResults.append(entry)
                if !incremental || totalRecords > startIndex {
                    incrementalResults.append(entry)
                }
            } catch {
                rejectedCount += 1
                let preview = String(raw.prefix(200))
                ErrorLogger.shared.log("Malformed JSONL line \(totalRecords) in \(url.lastPathComponent): \(preview)", level: "WARN")
                if recordDecodeFailureAndMaybeQuarantine(for: url) {
                    return false
                }
            }
            return true
        }

        if incremental {
            lineCheckpoints[url] = max(0, startIndex)
            lineCheckpointsDirty = true
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
                recordBuffer.append(byte)
                if inString {
                    if escaping {
                        escaping = false
                    } else if byte == 0x5C { // "\"
                        escaping = true
                    } else if byte == 0x22 { // "\""
                        inString = false
                    }
                    continue
                }
                if byte == 0x22 { // "\""
                    inString = true
                    continue
                }
                if byte == 0x7B { // "{"
                    braceDepth += 1
                    continue
                }
                if byte == 0x7D, braceDepth > 0 { // "}"
                    braceDepth -= 1
                }

                let isBoundaryNewline = byte == 0x0A && braceDepth == 0
                let isBoundaryObjectClose = byte == 0x7D && braceDepth == 0
                if isBoundaryNewline || isBoundaryObjectClose {
                    if !processRecord(recordBuffer) {
                        break parseLoop
                    }
                    recordBuffer.removeAll(keepingCapacity: true)
                }
            }
        }

        if !recordBuffer.isEmpty {
            _ = processRecord(recordBuffer)
        }

        var results = incremental ? incrementalResults : allResults
        if incremental {
            let prev = startIndex
            if prev > totalRecords {
                ErrorLogger.shared.log(
                    "Claude checkpoint exceeds current line count for \(url.lastPathComponent); resetting checkpoint (file truncated or rotated)",
                    level: "WARN"
                )
                lineCheckpoints[url] = totalRecords
                lineCheckpointsDirty = true
                results = allResults
            } else {
                lineCheckpoints[url] = totalRecords
                lineCheckpointsDirty = true
            }
            if deferPersistence {
                // persisted once per aggregate cycle
            } else {
                if lineCheckpointsDirty {
                    persistLineCheckpoints()
                    lineCheckpointsDirty = false
                }
            }
        }
        ParserMetricsStore.shared.record(
            parser: "claude_code",
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
        let quarantineDir = claudeDir.appendingPathComponent("quarantine")
        try? FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        let destination = quarantineDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            lineCheckpoints.removeValue(forKey: url)
            persistLineCheckpoints()
            fileChecksums.removeValue(forKey: url)
            ErrorLogger.shared.log("Quarantined corrupt Claude log file \(url.lastPathComponent) after repeated decode failures", level: "WARN")
            return true
        } catch {
            ErrorLogger.shared.log("Failed to quarantine corrupt Claude log file \(url.lastPathComponent): \(error.localizedDescription)", level: "WARN")
            return false
        }
    }

    // Some appenders write JSON objects without newline delimiters.
    // Normalize `}{` boundaries into newline-separated JSONL records.
    private func normalizeConcatenatedJSONObjects(_ text: String) -> String {
        var normalized = String()
        normalized.reserveCapacity(text.count + 32)
        var inString = false
        var escaping = false
        var pendingBoundary = false

        for ch in text {
            if inString {
                normalized.append(ch)
                if escaping {
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                normalized.append(ch)
                inString = true
                continue
            }

            if ch.isWhitespace {
                normalized.append(ch)
                continue
            }

            if pendingBoundary, ch == "{", normalized.last?.isNewline != true {
                normalized.append("\n")
            }
            normalized.append(ch)
            pendingBoundary = (ch == "}")
        }

        return normalized
    }

    func aggregateToday() -> UsageSnapshot {
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.year,.month,.day], from: Date())
        if dailyAccumulator?.day != todayComps {
            dailyAccumulator = DailyAccumulator(day: todayComps, input: 0, output: 0, cacheCreate: 0, cacheRead: 0)
            dailyAccumulatorDirty = true
        }
        for url in discoverSessionFiles() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mod = attrs?[.modificationDate] as? Date
            let size = (attrs?[.size] as? Int) ?? -1
            let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
            guard let mod else { continue }
            if let prev = fileChecksums[url], prev.0 == mod, prev.1 == size, prev.2 == inode { continue }
            fileChecksums[url] = (mod, size, inode)
            for entry in parseFile(url, incremental: true, deferPersistence: true) {
                guard let entryDate = entryTimestamp(entry, fallback: mod),
                      cal.dateComponents([.year,.month,.day], from: entryDate) == todayComps else { continue }
                let u = entry.usage ?? entry.message?.usage
                dailyAccumulator?.input += u?.input_tokens ?? 0
                dailyAccumulator?.output += u?.output_tokens ?? 0
                dailyAccumulator?.cacheCreate += u?.cache_creation_input_tokens ?? 0
                dailyAccumulator?.cacheRead += u?.cache_read_input_tokens ?? 0
                dailyAccumulatorDirty = true
            }
        }
        flushPersistedState()
        let acc = dailyAccumulator ?? DailyAccumulator(day: todayComps, input: 0, output: 0, cacheCreate: 0, cacheRead: 0)
        return UsageSnapshot(
            accountId: UUID(), // overridden by caller with real account id
            timestamp: Date(),
            inputTokens: acc.input,
            outputTokens: acc.output,
            cacheCreationTokens: acc.cacheCreate,
            cacheReadTokens: acc.cacheRead,
            totalCostUSD: 0, // local logs lack pricing
            modelBreakdown: [ModelUsage(modelId: "claude-code-local", inputTokens: acc.input, outputTokens: acc.output, cacheTokens: acc.cacheCreate + acc.cacheRead, costUSD: 0)], // task 91
            costConfidence: .estimated
        )
    }

    func aggregatePeriod(days: Int) -> [UsageSnapshot] {
        let cal = Calendar.current
        var dayMap: [DateComponents: (Int,Int,Int,Int)] = [:]
        for url in discoverSessionFiles() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mod = attrs?[.modificationDate] as? Date
            for entry in parseFile(url) {
                let u = entry.usage ?? entry.message?.usage
                guard let eventDate = entryTimestamp(entry, fallback: mod) else { continue }
                let comps = cal.dateComponents([.year,.month,.day], from: eventDate)
                let prev = dayMap[comps] ?? (0,0,0,0)
                dayMap[comps] = (
                    prev.0 + (u?.input_tokens ?? 0),
                    prev.1 + (u?.output_tokens ?? 0),
                    prev.2 + (u?.cache_creation_input_tokens ?? 0),
                    prev.3 + (u?.cache_read_input_tokens ?? 0)
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
                cacheCreationTokens: vals.2,
                cacheReadTokens: vals.3,
                totalCostUSD: 0,
                modelBreakdown: [],
                costConfidence: .estimated
            )
        }.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: – FSEvents watcher

    func startWatching() {
        stopWatching()
        let projectsDir = claudeDir.appendingPathComponent("projects")
        var watchPaths = [projectsDir.path]
        if let subs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) {
            for sub in subs {
                if (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    watchPaths.append(sub.path)
                }
            }
        }
        let paths = watchPaths as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let p = info else { return }
            Unmanaged<ClaudeCodeLogParser>.fromOpaque(p).takeUnretainedValue().debounceLogsChanged()
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
        fallbackTimer?.invalidate(); fallbackTimer = nil
        guard let s = fsEventStream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        fsEventStream = nil
    }

    private func debounceLogsChanged() { // 500ms debounce
        lastFSEventDate = Date()
        debounceWork?.cancel()
        let w = DispatchWorkItem {
            NotificationCenter.default.post(name: .claudeCodeLogsChanged, object: nil)
        }
        debounceWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func entryTimestamp(_ entry: ClaudeCodeEntry, fallback: Date?) -> Date? {
        for raw in [entry.timestamp, entry.created_at, entry.time].compactMap({ $0 }) {
            if let parsed = isoTimestamp.date(from: raw) ?? isoTimestampNoFraction.date(from: raw) {
                return parsed
            }
        }
        return fallback
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

    private func persistLineCheckpoints() {
        let raw = Dictionary(uniqueKeysWithValues: lineCheckpoints.map { ($0.key.path, $0.value) })
        do {
            let data = try JSONEncoder().encode(raw)
            try data.write(to: checkpointFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Failed to persist Claude Code checkpoints: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func persistDailyAccumulator() {
        guard let dailyAccumulator else { return }
        do {
            let data = try JSONEncoder().encode(PersistedDailyAccumulator(from: dailyAccumulator))
            try data.write(to: accumulatorFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Failed to persist Claude Code daily accumulator: \(error.localizedDescription)", level: "WARN")
        }
    }

    private func flushPersistedState() {
        if lineCheckpointsDirty {
            persistLineCheckpoints()
            lineCheckpointsDirty = false
        }
        if dailyAccumulatorDirty {
            persistDailyAccumulator()
            dailyAccumulatorDirty = false
        }
    }
}

extension Notification.Name {
    static let claudeCodeLogsChanged = Notification.Name("ClaudeCodeLogsChanged")
}
