import WidgetKit
import SwiftUI

// MARK: - shared data reader

private struct WidgetUsageData {
    var totalCostToday: Double
    var totalTokensToday: Int
    var accountCount: Int
    var lastUpdated: Date?
}

private func loadWidgetData() -> WidgetUsageData {
    let groupID = "group.dev.claudeusage"
    guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
        return WidgetUsageData(totalCostToday: 0, totalTokensToday: 0, accountCount: 0, lastUpdated: nil)
    }
    let cacheFile = containerURL.appendingPathComponent("usage_cache.json")
    guard let data = try? Data(contentsOf: cacheFile) else {
        return WidgetUsageData(totalCostToday: 0, totalTokensToday: 0, accountCount: 0, lastUpdated: nil)
    }
    let decoder = JSONDecoder()
    let fractionalFmt = ISO8601DateFormatter()
    fractionalFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plainFmt = ISO8601DateFormatter()
    plainFmt.formatOptions = [.withInternetDateTime]
    decoder.dateDecodingStrategy = .custom { dec in
        let raw = try dec.singleValueContainer().decode(String.self)
        if let d = fractionalFmt.date(from: raw) ?? plainFmt.date(from: raw) { return d }
        throw DecodingError.dataCorruptedError(in: try dec.singleValueContainer(), debugDescription: "Invalid date: \(raw)")
    }
    guard let payload = try? decoder.decode(WidgetCachePayload.self, from: data) else {
        return WidgetUsageData(totalCostToday: 0, totalTokensToday: 0, accountCount: 0, lastUpdated: nil)
    }
    let cal = Calendar.current
    let todayStart = cal.startOfDay(for: Date())
    let todaySnapshots = payload.snapshots.filter { $0.timestamp >= todayStart }
    let accounts = Set(todaySnapshots.map(\.accountId))
    let cost = todaySnapshots.reduce(0.0) { $0 + $1.totalCostUSD }
    let tokens = todaySnapshots.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    let latest = todaySnapshots.max(by: { $0.timestamp < $1.timestamp })?.timestamp
    return WidgetUsageData(
        totalCostToday: cost,
        totalTokensToday: tokens,
        accountCount: accounts.count,
        lastUpdated: latest
    )
}

// MARK: - minimal decodable types (widget can't import main app)

private struct WidgetCachePayload: Decodable {
    var schemaVersion: Int
    var snapshots: [WidgetSnapshot]
}

private struct WidgetSnapshot: Decodable {
    var accountId: UUID
    var timestamp: Date
    var inputTokens: Int
    var outputTokens: Int
    var totalCostUSD: Double
}

// MARK: - timeline

struct SageBarEntry: TimelineEntry {
    let date: Date
    let cost: Double
    let tokens: Int
    let accounts: Int
    let lastUpdated: Date?
}

struct SageBarProvider: TimelineProvider {
    func placeholder(in context: Context) -> SageBarEntry {
        SageBarEntry(date: Date(), cost: 1.23, tokens: 50000, accounts: 2, lastUpdated: Date())
    }
    func getSnapshot(in context: Context, completion: @escaping (SageBarEntry) -> Void) {
        let data = loadWidgetData()
        completion(SageBarEntry(
            date: Date(), cost: data.totalCostToday, tokens: data.totalTokensToday,
            accounts: data.accountCount, lastUpdated: data.lastUpdated
        ))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SageBarEntry>) -> Void) {
        let data = loadWidgetData()
        let entry = SageBarEntry(
            date: Date(), cost: data.totalCostToday, tokens: data.totalTokensToday,
            accounts: data.accountCount, lastUpdated: data.lastUpdated
        )
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - views

struct SageBarWidgetEntryView: View {
    var entry: SageBarEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall: smallView
        case .systemMedium: mediumView
        default: smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text("Sage Bar")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(String(format: "$%.4f", entry.cost))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
            Text("today")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            if let last = entry.lastUpdated {
                Text(last, style: .relative)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    private var mediumView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .foregroundColor(.orange)
                    Text("Sage Bar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(String(format: "$%.4f", entry.cost))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text("today")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                statRow(icon: "arrow.left.arrow.right", label: "Tokens", value: formatTokens(entry.tokens))
                statRow(icon: "person.2", label: "Accounts", value: "\(entry.accounts)")
                if let last = entry.lastUpdated {
                    statRow(icon: "clock", label: "Updated", value: "")
                    Text(last, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private func statRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
        }
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1_000_000) :
        count >= 1000 ? "\(count / 1000)k" : "\(count)"
    }
}

// MARK: - widget definition

@main
struct SageBarWidget: Widget {
    let kind = "dev.claudeusage.widget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SageBarProvider()) { entry in
            SageBarWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Sage Bar")
        .description("Today's AI token usage and spend.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
