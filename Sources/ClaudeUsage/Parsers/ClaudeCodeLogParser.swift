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
    private var fileChecksums: [URL: (Date, Int)] = [:] // mtime+size cache for skip-unchanged
    private var fsEventStream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var lastFSEventDate: Date?

    private init() {
        self.claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
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

    func parseFile(_ url: URL) -> [ClaudeCodeEntry] {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 50 * 1024 * 1024 {
            ErrorLogger.shared.log("Skipping oversized log file \(url.lastPathComponent) (\(size / 1024 / 1024)MB)", level: "WARN")
            return []
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            ErrorLogger.shared.log("Cannot read log file at \(url.path): \(error.localizedDescription)")
            return []
        }
        let dec = JSONDecoder()
        var results: [ClaudeCodeEntry] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            do {
                results.append(try dec.decode(ClaudeCodeEntry.self, from: Data(line.utf8)))
            } catch {
                let preview = String(line.prefix(200))
                ErrorLogger.shared.log("Malformed JSONL line \(i+1) in \(url.lastPathComponent): \(preview)", level: "WARN")
            }
        }
        return results
    }

    func aggregateToday() -> UsageSnapshot {
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.year,.month,.day], from: Date())
        var input = 0, output = 0, cacheCreate = 0, cacheRead = 0
        for url in discoverSessionFiles() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let mod = attrs?[.modificationDate] as? Date,
                  cal.dateComponents([.year,.month,.day], from: mod) == todayComps else { continue }
            let size = (attrs?[.size] as? Int) ?? -1
            if let prev = fileChecksums[url], prev.0 == mod, prev.1 == size { continue }
            fileChecksums[url] = (mod, size)
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
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
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
}

extension Notification.Name {
    static let claudeCodeLogsChanged = Notification.Name("ClaudeCodeLogsChanged")
}
