import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject private var errorLogger = ErrorLogger.shared
    @ObservedObject private var polling = PollingService.shared
    @State private var entries: [String] = []
    @State private var parserMetrics: [ParserMetricsSnapshot] = []
    
    @MainActor
    private var pollSkipSummary: String {
        let totals = polling.pollSkipTotalsOrdered()
        let parts = totals.map { "\($0.0.label): \($0.1)" }
        return parts.joined(separator: " | ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries.indices, id: \.self) { i in
                        Text(entries[i])
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(entries[i].contains("[ERROR]") ? .red : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(8)
            }
            Divider()
            HStack {
                Text("\(entries.count) entries").font(.caption).foregroundColor(.secondary)
                Text("Poll p50: \(polling.pollDurationP50Ms)ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Poll p90: \(polling.pollDurationP90Ms)ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entries.joined(separator: "\n"), forType: .string)
                }
                Button("Clear Errors") {
                    errorLogger.clearLog()
                    entries = []
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            HStack {
                Text("Poll skips: \(pollSkipSummary)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            if !parserMetrics.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parser metrics")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(parserMetrics) { metric in
                        Text(
                            "\(metric.parser) runs:\(metric.runs) files:\(metric.filesScanned) parsed:\(metric.linesParsed) rejected:\(metric.linesRejected) cpu:\(metric.cpuTimeMs)ms wall:\(metric.wallTimeMs)ms"
                        )
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            entries = errorLogger.readLast(50)
            reloadParserMetrics()
        }
        .onReceive(errorLogger.$lastError) { _ in
            entries = errorLogger.readLast(50)
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageDidUpdate)) { _ in
            reloadParserMetrics()
        }
    }

    private func reloadParserMetrics() {
        parserMetrics = ParserMetricsStore.shared.snapshot()
    }
}
