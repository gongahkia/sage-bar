import Foundation
import CoreServices

private struct GeminiConversationRecord: Codable {
    var messages: [GeminiMessageRecord]
}

private struct GeminiMessageRecord: Codable {
    var timestamp: String?
    var type: String?
    var tokens: GeminiMessageTokens?
    var model: String?
}

private struct GeminiMessageTokens: Codable {
    var input: Int?
    var output: Int?
    var cached: Int?
}

private struct GeminiDailyFileUsage {
    var day: DateComponents
    var input: Int
    var output: Int
    var cacheRead: Int
    var modelTotals: [String: (input: Int, output: Int, cacheRead: Int)]
}

private struct PersistedGeminiModelTotals: Codable {
    var input: Int
    var output: Int
    var cacheRead: Int
}

private struct PersistedGeminiDailyFileUsage: Codable {
    var year: Int
    var month: Int
    var day: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var modelTotals: [String: PersistedGeminiModelTotals]

    init(from usage: GeminiDailyFileUsage) {
        self.year = usage.day.year ?? 0
        self.month = usage.day.month ?? 0
        self.day = usage.day.day ?? 0
        self.input = usage.input
        self.output = usage.output
        self.cacheRead = usage.cacheRead
        self.modelTotals = usage.modelTotals.mapValues {
            PersistedGeminiModelTotals(input: $0.input, output: $0.output, cacheRead: $0.cacheRead)
        }
    }

    var asUsage: GeminiDailyFileUsage {
        GeminiDailyFileUsage(
            day: DateComponents(year: year, month: month, day: day),
            input: input,
            output: output,
            cacheRead: cacheRead,
            modelTotals: modelTotals.mapValues { ($0.input, $0.output, $0.cacheRead) }
        )
    }
}

private struct PersistedGeminiFileCheckpoint: Codable {
    var modifiedAt: Date
    var size: Int
    var inode: UInt64?
    var usage: PersistedGeminiDailyFileUsage
}

class GeminiLogParser {
    static let shared = GeminiLogParser()

    private let geminiDir: URL
    private let fallbackInterval: TimeInterval
    private let checkpointFile: URL
    private var fsEventStream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var lastFSEventDate: Date?

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

    private var fileChecksums: [URL: (Date, Int, UInt64?)] = [:] // mtime + size + inode
    private var fileDailyUsage: [URL: GeminiDailyFileUsage] = [:]
    private var missingDirLogged = false

    private init() {
        self.geminiDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
        self.fallbackInterval = 60
        self.checkpointFile = AppConstants.sharedContainerURL.appendingPathComponent("gemini_file_checkpoints.json")
        let loaded = Self.loadCheckpoints(from: self.checkpointFile)
        self.fileChecksums = loaded.checksums
        self.fileDailyUsage = loaded.usage
    }

    internal init(geminiDir: URL, fallbackInterval: TimeInterval = 60, checkpointFile: URL? = nil) {
        self.geminiDir = geminiDir
        self.fallbackInterval = fallbackInterval
        self.checkpointFile = checkpointFile ?? geminiDir.appendingPathComponent("gemini_file_checkpoints.json")
        let loaded = Self.loadCheckpoints(from: self.checkpointFile)
        self.fileChecksums = loaded.checksums
        self.fileDailyUsage = loaded.usage
    }

    func discoverSessionFiles() -> [URL] {
        let sessionsRoot = geminiDir.appendingPathComponent("tmp")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDir), isDir.boolValue else {
            if !missingDirLogged {
                ErrorLogger.shared.log("Gemini session directory not found at \(sessionsRoot.path)", level: "WARN")
                missingDirLogged = true
            }
            return []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "json" && $0.path.contains("/chats/")
        }
    }

    private func parseFile(_ url: URL) -> GeminiConversationRecord? {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 50 * 1024 * 1024 {
            ErrorLogger.shared.log("Skipping oversized Gemini session file \(url.lastPathComponent)", level: "WARN")
            return nil
        }
        let wallStartNanos = DispatchTime.now().uptimeNanoseconds
        let cpuStartMs = ParserMetricsStore.currentProcessCPUTimeMs()
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(GeminiConversationRecord.self, from: data)
            ParserMetricsStore.shared.record(
                parser: "gemini",
                filesScanned: 1,
                linesParsed: record.messages.count,
                linesRejected: 0,
                bytesRead: data.count,
                cpuTimeMs: max(0, ParserMetricsStore.currentProcessCPUTimeMs() - cpuStartMs),
                wallTimeMs: Int((DispatchTime.now().uptimeNanoseconds - wallStartNanos) / 1_000_000)
            )
            return record
        } catch {
            ErrorLogger.shared.log("Cannot parse Gemini session file at \(url.path): \(error.localizedDescription)", level: "WARN")
            ParserMetricsStore.shared.record(
                parser: "gemini",
                filesScanned: 1,
                linesParsed: 0,
                linesRejected: 1,
                bytesRead: 0,
                cpuTimeMs: max(0, ParserMetricsStore.currentProcessCPUTimeMs() - cpuStartMs),
                wallTimeMs: Int((DispatchTime.now().uptimeNanoseconds - wallStartNanos) / 1_000_000)
            )
            return nil
        }
    }

    func aggregateToday() -> UsageSnapshot {
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.year, .month, .day], from: Date())
        let files = discoverSessionFiles()
        let fileSet = Set(files)
        fileDailyUsage = fileDailyUsage.filter { fileSet.contains($0.key) }
        fileChecksums = fileChecksums.filter { fileSet.contains($0.key) }

        for url in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let mod = attrs?[.modificationDate] as? Date else { continue }
            let size = (attrs?[.size] as? Int) ?? -1
            let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
            if let prev = fileChecksums[url],
               prev.0 == mod, prev.1 == size, prev.2 == inode,
               fileDailyUsage[url]?.day == todayComps {
                continue
            }
            fileChecksums[url] = (mod, size, inode)
            guard let record = parseFile(url) else { continue }
            fileDailyUsage[url] = computeDailyUsage(record: record, day: todayComps, fallbackDate: mod)
        }
        persistCheckpoints()

        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var mergedByModel: [String: (input: Int, output: Int, cacheRead: Int)] = [:]

        for usage in fileDailyUsage.values where usage.day == todayComps {
            totalInput += usage.input
            totalOutput += usage.output
            totalCacheRead += usage.cacheRead
            for (model, totals) in usage.modelTotals {
                let prev = mergedByModel[model] ?? (0, 0, 0)
                mergedByModel[model] = (
                    prev.input + totals.input,
                    prev.output + totals.output,
                    prev.cacheRead + totals.cacheRead
                )
            }
        }

        var detailedBreakdown: [ModelUsage] = []
        detailedBreakdown.reserveCapacity(mergedByModel.count)
        for (model, totals) in mergedByModel {
            detailedBreakdown.append(
                ModelUsage(
                    modelId: model,
                    inputTokens: totals.input,
                    outputTokens: totals.output,
                    cacheTokens: totals.cacheRead,
                    costUSD: 0
                )
            )
        }
        detailedBreakdown.sort {
            ($0.inputTokens + $0.outputTokens + $0.cacheTokens) > ($1.inputTokens + $1.outputTokens + $1.cacheTokens)
        }

        var breakdown: [ModelUsage] = [
            ModelUsage(
                modelId: "gemini-local",
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheTokens: totalCacheRead,
                costUSD: 0
            )
        ]
        for item in detailedBreakdown where item.modelId != "gemini-local" {
            breakdown.append(item)
        }

        return UsageSnapshot(
            accountId: UUID(), // overridden by caller
            timestamp: Date(),
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: 0,
            cacheReadTokens: totalCacheRead,
            totalCostUSD: 0,
            modelBreakdown: breakdown,
            costConfidence: .estimated
        )
    }

    private func computeDailyUsage(
        record: GeminiConversationRecord,
        day: DateComponents,
        fallbackDate: Date?
    ) -> GeminiDailyFileUsage {
        let cal = Calendar.current
        var input = 0
        var output = 0
        var cacheRead = 0
        var modelTotals: [String: (input: Int, output: Int, cacheRead: Int)] = [:]

        for message in record.messages {
            guard message.type == "gemini",
                  let tokens = message.tokens else { continue }
            guard let eventDate = entryTimestamp(raw: message.timestamp, fallback: fallbackDate) else { continue }
            let eventDay = cal.dateComponents([.year, .month, .day], from: eventDate)
            guard eventDay == day else { continue }
            let inputTokens = max(0, tokens.input ?? 0)
            let outputTokens = max(0, tokens.output ?? 0)
            let cacheTokens = max(0, tokens.cached ?? 0)
            input += inputTokens
            output += outputTokens
            cacheRead += cacheTokens
            let model = canonicalModelID(message.model)
            let prev = modelTotals[model] ?? (0, 0, 0)
            modelTotals[model] = (
                prev.input + inputTokens,
                prev.output + outputTokens,
                prev.cacheRead + cacheTokens
            )
        }

        return GeminiDailyFileUsage(
            day: day,
            input: input,
            output: output,
            cacheRead: cacheRead,
            modelTotals: modelTotals
        )
    }

    private func entryTimestamp(raw: String?, fallback: Date?) -> Date? {
        guard let raw else { return fallback }
        return isoTimestamp.date(from: raw) ?? isoTimestampNoFraction.date(from: raw) ?? fallback
    }

    private func canonicalModelID(_ model: String?) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "gemini-local" : trimmed
    }

    // MARK: - FSEvents watcher

    func startWatching() {
        stopWatching()
        let sessionsDir = geminiDir.appendingPathComponent("tmp")
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
            Unmanaged<GeminiLogParser>.fromOpaque(p).takeUnretainedValue().debounceLogsChanged()
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

    private func debounceLogsChanged() {
        lastFSEventDate = Date()
        debounceWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .geminiLogsChanged, object: nil)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func loadCheckpoints(from file: URL) -> (
        checksums: [URL: (Date, Int, UInt64?)],
        usage: [URL: GeminiDailyFileUsage]
    ) {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode([String: PersistedGeminiFileCheckpoint].self, from: data) else {
            return ([:], [:])
        }
        var checksums: [URL: (Date, Int, UInt64?)] = [:]
        var usage: [URL: GeminiDailyFileUsage] = [:]
        for (path, checkpoint) in raw {
            let url = URL(fileURLWithPath: path)
            checksums[url] = (checkpoint.modifiedAt, checkpoint.size, checkpoint.inode)
            usage[url] = checkpoint.usage.asUsage
        }
        return (checksums, usage)
    }

    private func persistCheckpoints() {
        var raw: [String: PersistedGeminiFileCheckpoint] = [:]
        for (url, checksum) in fileChecksums {
            guard let usage = fileDailyUsage[url] else { continue }
            raw[url.path] = PersistedGeminiFileCheckpoint(
                modifiedAt: checksum.0,
                size: checksum.1,
                inode: checksum.2,
                usage: PersistedGeminiDailyFileUsage(from: usage)
            )
        }
        do {
            try FileManager.default.createDirectory(at: AppConstants.sharedContainerURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(raw)
            try data.write(to: checkpointFile, options: .atomic)
        } catch {
            ErrorLogger.shared.log("Failed to persist Gemini checkpoints: \(error.localizedDescription)", level: "WARN")
        }
    }
}

extension Notification.Name {
    static let geminiLogsChanged = Notification.Name("GeminiLogsChanged")
}
