import SwiftUI
import Charts

struct HistoryView: View {
    let account: Account?
    @State private var tab = 0
    @State private var snapshots: [UsageSnapshot] = []
    private var config: AnalyticsConfig { ConfigManager.shared.load().analytics }

    var body: some View {
        Group {
            if !config.enabled {
                Text("Analytics is disabled. Enable in Settings → Analytics.")
                    .foregroundColor(.secondary).padding()
            } else {
                VStack {
                    Picker("", selection: $tab) {
                        Text("7 Day").tag(0)
                        Text("30 Day").tag(1)
                        Text("MTD").tag(2)
                        Text("Heatmap").tag(3)
                    }.pickerStyle(.segmented).padding()
                    switch tab {
                    case 0: sevenDayChart
                    case 1: thirtyDayChart
                    case 2: mtdView
                    default: heatmapView
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
        .task(id: account?.id) {
            await reloadSnapshots()
        }
    }

    // MARK: – 7-day
    private var sevenDayChart: some View {
        let byDay = grouped(sevenDaySnapshots)
        return Chart(byDay, id: \.0) {
            BarMark(x: .value("Day", $0.0, unit: .day), y: .value("Cost", $0.1))
        }.frame(height: 200).padding()
    }

    // MARK: – 30-day
    private var thirtyDayChart: some View {
        let byDay = grouped(snapshots)
        return Chart(byDay, id: \.0) {
            BarMark(x: .value("Day", $0.0, unit: .day), y: .value("Cost", $0.1))
        }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisTick(); AxisGridLine() } }
        .frame(height: 200).padding()
    }

    // MARK: – MTD
    private var mtdView: some View {
        let accountId = account?.id ?? UUID()
        let agg = AnalyticsEngine.monthToDate(snapshots: snapshots, account: accountId)
        let byDay = Dictionary(grouping: agg.snapshots) {
            Calendar.current.startOfDay(for: $0.timestamp)
        }.mapValues { $0.reduce(0) { $0 + $1.totalCostUSD } }
        let highest = byDay.max(by: { $0.value < $1.value })
        let avg = byDay.isEmpty ? 0 : byDay.values.reduce(0,+) / Double(byDay.count)
        let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .none
        return VStack(alignment: .leading, spacing: 8) {
            statRow("Total Cost", v: String(format: "$%.4f", agg.totalCostUSD))
            statRow("Input Tokens", v: agg.totalInputTokens.formatted())
            statRow("Output Tokens", v: agg.totalOutputTokens.formatted())
            statRow("Daily Average", v: String(format: "$%.4f", avg))
            if let h = highest {
                statRow("Peak Day", v: "\(fmt.string(from: h.key)) — \(String(format: "$%.4f", h.value))")
            }
        }.padding()
    }

    // MARK: – Heatmap
    private var heatmapView: some View {
        if !config.showHeatmap {
            return AnyView(Text("Enable heatmap in Analytics settings").foregroundColor(.secondary).padding())
        }
        let accountId = account?.id ?? UUID()
        let grid = AnalyticsEngine.heatmap(snapshots: snapshots, account: accountId)
        let days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
        return AnyView(
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<7, id: \.self) { wi in
                    GridRow {
                        Text(days[wi]).font(.caption2).frame(width: 28)
                        ForEach(0..<24, id: \.self) { hi in
                            let v = grid[wi][hi]
                            Rectangle()
                                .fill(Color(hue: 0.6, saturation: 1, brightness: 0.3 + v * 0.7))
                                .frame(width: 14, height: 14)
                        }
                    }
                }
            }.padding()
        )
    }

    private func grouped(_ snaps: [UsageSnapshot]) -> [(Date, Double)] {
        let cal = Calendar.current
        return Dictionary(grouping: snaps) { cal.startOfDay(for: $0.timestamp) }
            .map { day, daySnapshots in
                let normalized = normalizeDailySnapshots(daySnapshots)
                return (day, normalized.reduce(0) { $0 + $1.totalCostUSD })
            }
            .sorted { $0.0 < $1.0 }
    }

    private func normalizeDailySnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        var eventSnapshots: [UsageSnapshot] = []
        var cumulativeSnapshots: [UsageSnapshot] = []
        for snapshot in snapshots {
            if isCumulativeSnapshot(snapshot) {
                cumulativeSnapshots.append(snapshot)
            } else {
                eventSnapshots.append(snapshot)
            }
        }
        if let latestCumulative = cumulativeSnapshots.max(by: { $0.timestamp < $1.timestamp }) {
            eventSnapshots.append(latestCumulative)
        }
        return eventSnapshots
    }

    private func isCumulativeSnapshot(_ snapshot: UsageSnapshot) -> Bool {
        let model = snapshot.modelBreakdown.first?.modelId ?? ""
        let cumulativeModels: Set<String> = [
            "claude-code-local",
            "claude-ai-web",
            "codex-local",
            "gemini-local",
            "openai-org",
            "windsurf-enterprise",
            "copilot-metrics",
        ]
        return cumulativeModels.contains(model)
    }

    private var sevenDaySnapshots: [UsageSnapshot] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
        return snapshots.filter { $0.timestamp >= cutoff }
    }

    private func reloadSnapshots() async {
        guard let account else {
            snapshots = []
            return
        }
        snapshots = await CacheManager.shared.historyAsync(forAccount: account.id, days: 30)
    }

    private func statRow(_ label: String, v: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(v).monospacedDigit()
        }.font(.system(size: 13))
    }
}
