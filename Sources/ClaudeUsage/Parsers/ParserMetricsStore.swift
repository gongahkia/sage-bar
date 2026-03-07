import Foundation
import Darwin

private struct ParserMetrics: Codable {
    var runs: Int
    var filesScanned: Int
    var linesParsed: Int
    var linesRejected: Int
    var bytesRead: Int
    var cpuTimeMs: Int
    var wallTimeMs: Int

    init(
        runs: Int,
        filesScanned: Int,
        linesParsed: Int,
        linesRejected: Int,
        bytesRead: Int,
        cpuTimeMs: Int,
        wallTimeMs: Int
    ) {
        self.runs = runs
        self.filesScanned = filesScanned
        self.linesParsed = linesParsed
        self.linesRejected = linesRejected
        self.bytesRead = bytesRead
        self.cpuTimeMs = cpuTimeMs
        self.wallTimeMs = wallTimeMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        filesScanned = try c.decodeIfPresent(Int.self, forKey: .filesScanned) ?? 0
        linesParsed = try c.decodeIfPresent(Int.self, forKey: .linesParsed) ?? 0
        linesRejected = try c.decodeIfPresent(Int.self, forKey: .linesRejected) ?? 0
        bytesRead = try c.decodeIfPresent(Int.self, forKey: .bytesRead) ?? 0
        cpuTimeMs = try c.decodeIfPresent(Int.self, forKey: .cpuTimeMs) ?? 0
        wallTimeMs = try c.decodeIfPresent(Int.self, forKey: .wallTimeMs) ?? 0
    }
}

struct ParserMetricsSnapshot: Identifiable {
    var id: String { parser }
    var parser: String
    var runs: Int
    var filesScanned: Int
    var linesParsed: Int
    var linesRejected: Int
    var bytesRead: Int
    var cpuTimeMs: Int
    var wallTimeMs: Int
}

final class ParserMetricsStore {
    static let shared = ParserMetricsStore()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.claudeusage.parser.metrics", qos: .utility)

    private init() {
        fileURL = AppConstants.sharedContainerURL.appendingPathComponent("parser_metrics.json")
    }

    init(fileURL: URL) { // testable seam
        self.fileURL = fileURL
    }

    static func currentProcessCPUTimeMs() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let userMs = Int(usage.ru_utime.tv_sec) * 1_000 + Int(usage.ru_utime.tv_usec) / 1_000
        let systemMs = Int(usage.ru_stime.tv_sec) * 1_000 + Int(usage.ru_stime.tv_usec) / 1_000
        return Swift.max(0, userMs + systemMs)
    }

    func record(
        parser: String,
        filesScanned: Int,
        linesParsed: Int,
        linesRejected: Int,
        bytesRead: Int,
        cpuTimeMs: Int,
        wallTimeMs: Int
    ) {
        queue.async {
            var all: [String: ParserMetrics] = [:]
            if let data = try? Data(contentsOf: self.fileURL) {
                all = (try? JSONDecoder().decode([String: ParserMetrics].self, from: data)) ?? [:]
            }
            let prev = all[parser] ?? ParserMetrics(
                runs: 0,
                filesScanned: 0,
                linesParsed: 0,
                linesRejected: 0,
                bytesRead: 0,
                cpuTimeMs: 0,
                wallTimeMs: 0
            )
            all[parser] = ParserMetrics(
                runs: prev.runs + 1,
                filesScanned: prev.filesScanned + filesScanned,
                linesParsed: prev.linesParsed + linesParsed,
                linesRejected: prev.linesRejected + linesRejected,
                bytesRead: prev.bytesRead + bytesRead,
                cpuTimeMs: prev.cpuTimeMs + max(0, cpuTimeMs),
                wallTimeMs: prev.wallTimeMs + max(0, wallTimeMs)
            )
            do {
                let data = try JSONEncoder().encode(all)
                try AtomicFileWriter.write(data, to: self.fileURL)
            } catch {
                ErrorLogger.shared.log("Parser metrics write failed: \(error.localizedDescription)", level: "WARN")
            }
        }
    }

    func snapshot() -> [ParserMetricsSnapshot] {
        queue.sync {
            guard let data = try? Data(contentsOf: self.fileURL),
                  let all = try? JSONDecoder().decode([String: ParserMetrics].self, from: data) else { return [] }
            return all.map { parser, metrics in
                ParserMetricsSnapshot(
                    parser: parser,
                    runs: metrics.runs,
                    filesScanned: metrics.filesScanned,
                    linesParsed: metrics.linesParsed,
                    linesRejected: metrics.linesRejected,
                    bytesRead: metrics.bytesRead,
                    cpuTimeMs: metrics.cpuTimeMs,
                    wallTimeMs: metrics.wallTimeMs
                )
            }
            .sorted { $0.parser < $1.parser }
        }
    }
}
