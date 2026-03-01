import Foundation
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "ErrorLogger")

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

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-usage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logFile = dir.appendingPathComponent("errors.log")
    }

    internal init(logFile: URL) { // test injection only
        self.logFile = logFile
    }

    func log(_ message: String, level: String = "ERROR", file: String = #file, line: Int = #line) {
        let entry = "[\(isoTimestamp())] [\(level)] \(URL(fileURLWithPath: file).lastPathComponent):\(line) — \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
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
            self.append(entry)
            self.rotateIfNeeded()
        }
        let err = AppError(timestamp: Date(), message: message)
        DispatchQueue.main.async { [weak self] in self?.lastError = err }
    }

    func readLast(_ n: Int = 500) -> [String] {
        queue.sync {
            guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return Array(lines.suffix(n))
        }
    }

    func clearLog() { // task 84: truncate errors.log to 0 bytes
        queue.async { [weak self] in
            guard let self else { return }
            try? "".write(to: self.logFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: – private

    private func append(_ entry: String) {
        if let handle = FileHandle(forWritingAtPath: logFile.path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            handle.closeFile()
        } else {
            try? Data(entry.utf8).write(to: logFile, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path))?[.size] as? Int ?? 0
        let exceedsSize = size > maxBytes
        let exceedsLineLimit = lines.count > (retainLines + 1)
        guard exceedsSize || exceedsLineLimit else { return }

        var kept = Array(lines.suffix(retainLines))
        kept.append("[\(isoTimestamp())] [INFO] ErrorLogger:0 - Log rotated (kept last \(retainLines) lines)")
        let rotated = kept.joined(separator: "\n") + "\n"
        try? rotated.write(to: logFile, atomically: true, encoding: .utf8)
    }

    private func isoTimestamp() -> String {
        SharedDateFormatters.iso8601InternetDateTime.string(from: Date())
    }
}
