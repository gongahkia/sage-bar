import Foundation

private struct ParserMetrics: Codable {
    var filesScanned: Int
    var linesParsed: Int
    var linesRejected: Int
    var bytesRead: Int
}

final class ParserMetricsStore {
    static let shared = ParserMetricsStore()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.claudeusage.parser.metrics", qos: .utility)

    private init() {
        fileURL = AppConstants.sharedContainerURL.appendingPathComponent("parser_metrics.json")
    }

    func record(parser: String, filesScanned: Int, linesParsed: Int, linesRejected: Int, bytesRead: Int) {
        queue.async {
            var all: [String: ParserMetrics] = [:]
            if let data = try? Data(contentsOf: self.fileURL) {
                all = (try? JSONDecoder().decode([String: ParserMetrics].self, from: data)) ?? [:]
            }
            let prev = all[parser] ?? ParserMetrics(filesScanned: 0, linesParsed: 0, linesRejected: 0, bytesRead: 0)
            all[parser] = ParserMetrics(
                filesScanned: prev.filesScanned + filesScanned,
                linesParsed: prev.linesParsed + linesParsed,
                linesRejected: prev.linesRejected + linesRejected,
                bytesRead: prev.bytesRead + bytesRead
            )
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? AtomicFileWriter.write(data, to: self.fileURL)
        }
    }
}
