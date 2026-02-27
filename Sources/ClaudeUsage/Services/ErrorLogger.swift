import Foundation
import OSLog

private let log = Logger(subsystem: "dev.claudeusage", category: "ErrorLogger")

final class ErrorLogger {
    static let shared = ErrorLogger()
    private let logFile: URL
    private let queue = DispatchQueue(label: "dev.claudeusage.errorlog", qos: .utility)
    private let maxBytes = 1_048_576 // 1MB
    private let retainLines = 500

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-usage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logFile = dir.appendingPathComponent("errors.log")
    }

    func log(_ message: String, level: String = "ERROR", file: String = #file, line: Int = #line) {
        let entry = "[\(isoTimestamp())] [\(level)] \(URL(fileURLWithPath: file).lastPathComponent):\(line) — \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            self.append(entry)
            self.rotateIfNeeded()
        }
    }

    func readLast(_ n: Int = 500) -> [String] {
        queue.sync {
            guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return Array(lines.suffix(n))
        }
    }

    func clear() {
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
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let text = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let kept = lines.suffix(retainLines).joined(separator: "\n") + "\n"
        try? kept.write(to: logFile, atomically: true, encoding: .utf8)
        log("Log rotated — kept last \(retainLines) lines", level: "INFO")
    }

    private func isoTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
