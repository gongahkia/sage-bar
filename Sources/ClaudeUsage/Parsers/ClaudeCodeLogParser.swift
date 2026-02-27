import Foundation
import OSLog
import CoreServices

private let log = Logger(subsystem: "dev.claudeusage", category: "LogParser")

// MARK: – JSONL schema types

struct ClaudeCodeEntry: Codable {
    var type: String
    var message: ClaudeMessage?
    var usage: ClaudeUsageField?
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
    static let shared = ClaudeCodeLogParser()
    private let claudeDir: URL
    private var modDates: [URL: Date] = [:] // cache for skip-unchanged optimisation
    private var fsEventStream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?

    private init() {
        self.claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    func discoverSessionFiles() -> [URL] {
        let projectsDir = claudeDir.appendingPathComponent("projects")
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    func parseFile(_ url: URL) -> [ClaudeCodeEntry] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            ErrorLogger.shared.log("Cannot read log file at \(url.path): \(error.localizedDescription)")
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            try? JSONDecoder().decode(ClaudeCodeEntry.self, from: Data(line.utf8))
        }
    }

    func aggregateToday() -> UsageSnapshot {
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.year,.month,.day], from: Date())
        var input = 0, output = 0, cacheCreate = 0, cacheRead = 0
        for url in discoverSessionFiles() {
            // skip files not modified today
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let mod = attrs?[.modificationDate] as? Date,
                  cal.dateComponents([.year,.month,.day], from: mod) == todayComps else { continue }
            // skip unchanged
            if let prev = modDates[url], prev == mod { continue }
            modDates[url] = mod
            for entry in parseFile(url) {
                let u = entry.usage ?? entry.message?.usage
                input += u?.input_tokens ?? 0
                output += u?.output_tokens ?? 0
                cacheCreate += u?.cache_creation_input_tokens ?? 0
                cacheRead += u?.cache_read_input_tokens ?? 0
            }
        }
        return UsageSnapshot(
            accountId: UUID(), // overridden by caller with real account id
            timestamp: Date(),
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            totalCostUSD: 0, // local logs lack pricing
            modelBreakdown: [ModelUsage(modelId: "claude-code-local", inputTokens: input, outputTokens: output, costUSD: 0)]
        )
    }

    func aggregatePeriod(days: Int) -> [UsageSnapshot] {
        let cal = Calendar.current
        var dayMap: [DateComponents: (Int,Int,Int,Int)] = [:]
        for url in discoverSessionFiles() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mod = (attrs?[.modificationDate] as? Date) ?? Date()
            for entry in parseFile(url) {
                let u = entry.usage ?? entry.message?.usage
                let comps = cal.dateComponents([.year,.month,.day], from: mod)
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
                modelBreakdown: []
            )
        }.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: – FSEvents watcher

    func startWatching() {
        stopWatching()
        let projectsPath = claudeDir.appendingPathComponent("projects").path
        let paths = [projectsPath] as CFArray
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
    }

    func stopWatching() {
        guard let s = fsEventStream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        fsEventStream = nil
    }

    private func debounceLogsChanged() { // 500ms debounce
        debounceWork?.cancel()
        let w = DispatchWorkItem {
            NotificationCenter.default.post(name: .claudeCodeLogsChanged, object: nil)
        }
        debounceWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
}

extension Notification.Name {
    static let claudeCodeLogsChanged = Notification.Name("ClaudeCodeLogsChanged")
}
