import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.claudeusage", category: "ErrorLogger")

struct AppError {
    let timestamp: Date
    let message: String
}

final class ErrorLogger: ObservableObject {
    static let shared = ErrorLogger()
    @Published var lastError: AppError?
    private let logFile: URL
    private let queue = DispatchQueue(label: "dev.claudeusage.errorlog", qos: .utility)
    private let maxBytes = 1_048_576 // 1MB
    private let retainLines = 500
    private var recentLogKeys: [String: Date] = [:]
    private let dedupWindowSeconds: TimeInterval = 30

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-usage")
        self.logFile = dir.appendingPathComponent("errors.log")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "Failed to create error log directory: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    internal init(logFile: URL) { // test injection only
        self.logFile = logFile
    }

    func log(_ message: String, level: String = "ERROR", file: String = #file, line: Int = #line) {
        let entry = "[\(isoTimestamp())] [\(level)] \(URL(fileURLWithPath: file).lastPathComponent):\(line) — \(message)\n"
        let dedupKey = "\(level)|\(URL(fileURLWithPath: file).lastPathComponent):\(line)|\(message)"
        queue.async { [weak self] in
            guard let self else { return }
            if self.shouldSuppressLog(dedupKey) { return }
            self.append(entry)
            self.rotateIfNeeded()
        }
        let err = AppError(timestamp: Date(), message: message)
        DispatchQueue.main.async { [weak self] in self?.lastError = err }
    }

    func logStructured(
        _ message: String,
        level: String = "ERROR",
        metadata: [String: String],
        file: String = #file,
        line: Int = #line
    ) {
        var payload: [String: Any] = [
            "timestamp": isoTimestamp(),
            "level": level,
            "file": URL(fileURLWithPath: file).lastPathComponent,
            "line": line,
            "message": message,
        ]
        payload["metadata"] = metadata
        let entry: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            entry = json + "\n"
        } else {
            entry = "[\(isoTimestamp())] [\(level)] \(URL(fileURLWithPath: file).lastPathComponent):\(line) — \(message) metadata=\(metadata)\n"
        }
        queue.async { [weak self] in
            guard let self else { return }
            let dedupKey = "structured|\(payload["level"] ?? "ERROR")|\(payload["file"] ?? ""):\(payload["line"] ?? 0)|\(message)"
            if self.shouldSuppressLog(dedupKey) { return }
            self.append(entry)
            self.rotateIfNeeded()
        }
        let err = AppError(timestamp: Date(), message: message)
        DispatchQueue.main.async { [weak self] in self?.lastError = err }
    }

    func readLast(_ n: Int = 500) -> [String] {
        queue.sync { () -> [String] in
            let text: String
            do {
                text = try String(contentsOf: logFile, encoding: .utf8)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return []
            } catch {
                logger.warning(
                    "Failed to read error log file: \(error.localizedDescription, privacy: .public)"
                )
                return []
            }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return Array(lines.suffix(n))
        }
    }

    func clearLog() { // task 84: truncate errors.log to 0 bytes
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try "".write(to: self.logFile, atomically: true, encoding: .utf8)
            } catch {
                logger.warning(
                    "Failed to clear error log file: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: – private

    private func append(_ entry: String) {
        let data = Data(entry.utf8)
        if let handle = FileHandle(forWritingAtPath: logFile.path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            do {
                try data.write(to: logFile, options: .atomic)
            } catch {
                logger.error(
                    "Failed to create error log file: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func rotateIfNeeded() {
        let text: String
        do {
            text = try String(contentsOf: logFile, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            logger.warning(
                "Failed to read error log for rotation: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let size: Int
        do {
            size = (try FileManager.default.attributesOfItem(atPath: logFile.path))[.size] as? Int ?? 0
        } catch {
            logger.warning(
                "Failed to read error log size for rotation: \(error.localizedDescription, privacy: .public)"
            )
            size = text.utf8.count
        }
        let exceedsSize = size > maxBytes
        let exceedsLineLimit = lines.count > (retainLines + 1)
        guard exceedsSize || exceedsLineLimit else { return }

        var kept = Array(lines.suffix(retainLines))
        kept.append("[\(isoTimestamp())] [INFO] ErrorLogger:0 - Log rotated (kept last \(retainLines) lines)")
        let rotated = kept.joined(separator: "\n") + "\n"
        do {
            try rotated.write(to: logFile, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("Failed to write rotated error log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isoTimestamp() -> String {
        SharedDateFormatters.iso8601InternetDateTime.string(from: Date())
    }

    private func shouldSuppressLog(_ key: String) -> Bool {
        let now = Date()
        recentLogKeys = recentLogKeys.filter { now.timeIntervalSince($0.value) <= dedupWindowSeconds }
        if let previous = recentLogKeys[key], now.timeIntervalSince(previous) <= dedupWindowSeconds {
            return true
        }
        recentLogKeys[key] = now
        return false
    }
}
