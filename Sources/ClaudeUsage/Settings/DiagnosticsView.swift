import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject private var errorLogger = ErrorLogger.shared
    @ObservedObject private var polling = PollingService.shared
    @State private var entries: [String] = []

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
        }
        .onAppear { entries = errorLogger.readLast(50) }
        .onReceive(errorLogger.$lastError) { _ in
            entries = errorLogger.readLast(50)
        }
    }
}
