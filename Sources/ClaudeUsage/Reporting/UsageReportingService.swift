import AppKit
import Foundation

struct UsageReportRow: Equatable {
    let accountID: UUID
    let accountName: String
    let groupLabel: String?
    let providerType: AccountType
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalCostUSD: Double
    let costConfidence: String
    let lastUpdated: Date?
}

struct GroupRollupRow: Equatable {
    let groupLabel: String
    let accountCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalCostUSD: Double
    let lastUpdated: Date?
}

struct WorkstreamReportRow: Equatable {
    let accountID: UUID
    let accountName: String
    let providerType: AccountType
    let workstreamName: String
    let sourceCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
}

enum UsageReportingService {
    static func reportRow(for account: Account) -> UsageReportRow {
        reportRow(for: account, in: nil)
    }

    static func reportRow(for account: Account, in interval: DateInterval?) -> UsageReportRow {
        let usage = accountUsage(for: account, in: interval)
        return UsageReportRow(
            accountID: account.id,
            accountName: account.trimmedName.isEmpty ? account.resolvedDisplayName(among: [account]) : account.trimmedName,
            groupLabel: account.trimmedGroupLabel,
            providerType: account.type,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheTokens: usage.cacheTokens,
            totalCostUSD: usage.totalCostUSD,
            costConfidence: costConfidenceLabel(for: account, latestSnapshot: usage.latestSnapshot),
            lastUpdated: usage.lastUpdated
        )
    }

    static func reportRows(for accounts: [Account]) -> [UsageReportRow] {
        reportRows(for: accounts, in: nil)
    }

    static func reportRows(for accounts: [Account], in interval: DateInterval?) -> [UsageReportRow] {
        Account.sortedForDisplay(accounts).map { reportRow(for: $0, in: interval) }
    }

    static func groupRollupRows(for accounts: [Account], in interval: DateInterval) -> [GroupRollupRow] {
        let sortedAccounts = Account.sortedForDisplay(accounts)
        let grouped = Dictionary(grouping: sortedAccounts) { account in
            account.trimmedGroupLabel ?? "Ungrouped"
        }
        return grouped.map { groupLabel, groupAccounts in
            let rows = groupAccounts.map { reportRow(for: $0, in: interval) }
            return GroupRollupRow(
                groupLabel: groupLabel,
                accountCount: rows.count,
                inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
                outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
                cacheTokens: rows.reduce(0) { $0 + $1.cacheTokens },
                totalCostUSD: rows.reduce(0) { $0 + $1.totalCostUSD },
                lastUpdated: rows.compactMap(\.lastUpdated).max()
            )
        }
        .sorted { lhs, rhs in
            if lhs.groupLabel == "Ungrouped" { return false }
            if rhs.groupLabel == "Ungrouped" { return true }
            return lhs.groupLabel.localizedCaseInsensitiveCompare(rhs.groupLabel) == .orderedAscending
        }
    }

    static func workstreamRows(for account: Account, in interval: DateInterval) -> [WorkstreamReportRow] {
        guard account.type.supportsWorkstreamAttribution else { return [] }
        let grouped = Dictionary(grouping: localSessionUsage(for: account, in: interval)) { usage in
            account.resolvedWorkstreamLabel(for: usage.sourcePath)
        }
        return grouped.map { workstreamName, sessions in
            WorkstreamReportRow(
                accountID: account.id,
                accountName: account.trimmedName.isEmpty ? account.type.displayName : account.trimmedName,
                providerType: account.type,
                workstreamName: workstreamName,
                sourceCount: sessions.count,
                inputTokens: sessions.reduce(0) { $0 + $1.inputTokens },
                outputTokens: sessions.reduce(0) { $0 + $1.outputTokens },
                cacheTokens: sessions.reduce(0) { $0 + $1.cacheTokens }
            )
        }
        .sorted { lhs, rhs in
            let lhsTotal = lhs.inputTokens + lhs.outputTokens + lhs.cacheTokens
            let rhsTotal = rhs.inputTokens + rhs.outputTokens + rhs.cacheTokens
            if lhsTotal == rhsTotal {
                return lhs.workstreamName.localizedCaseInsensitiveCompare(rhs.workstreamName) == .orderedAscending
            }
            return lhsTotal > rhsTotal
        }
    }

    static func summaryText(for account: Account, among accounts: [Account]) -> String {
        summaryText(for: account, among: accounts, in: nil)
    }

    static func summaryText(for account: Account, among accounts: [Account], in interval: DateInterval?) -> String {
        let row = reportRow(for: account, in: interval)
        return summaryText(
            for: row,
            displayName: account.displayLabel(among: accounts),
            interval: interval
        )
    }

    static func summaryText(for accounts: [Account]) -> String {
        summaryText(for: accounts, in: nil)
    }

    static func summaryText(for accounts: [Account], in interval: DateInterval?) -> String {
        let sortedAccounts = Account.sortedForDisplay(accounts)
        return sortedAccounts
            .map { summaryText(for: $0, among: sortedAccounts, in: interval) }
            .joined(separator: "\n\n")
    }

    static func groupSummaryText(
        for groupLabel: String,
        in accounts: [Account],
        interval: DateInterval
    ) -> String {
        let normalizedGroupLabel = groupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupLabel.isEmpty else { return "No group selected." }
        let matchingAccounts = Account.sortedForDisplay(accounts).filter {
            ($0.trimmedGroupLabel ?? "Ungrouped").caseInsensitiveCompare(normalizedGroupLabel) == .orderedSame
        }
        guard !matchingAccounts.isEmpty else { return "No accounts found for group '\(normalizedGroupLabel)'." }
        let groupRow = groupRollupRows(for: matchingAccounts, in: interval).first
        var lines = [
            "Group: \(normalizedGroupLabel)",
            "Period: \(intervalLabel(for: interval))",
            "Accounts: \(matchingAccounts.count)",
            "Input Tokens: \((groupRow?.inputTokens ?? 0).formatted())",
            "Output Tokens: \((groupRow?.outputTokens ?? 0).formatted())",
            "Cache Tokens: \((groupRow?.cacheTokens ?? 0).formatted())",
            String(format: "Cost (USD): %.4f", groupRow?.totalCostUSD ?? 0),
            "Last Sync: \(groupRow?.lastUpdated.map(relativeTimestamp) ?? "Never")",
        ]
        lines.append("Members: \(matchingAccounts.map { $0.displayLabel(among: matchingAccounts) }.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    static func workstreamSummaryText(for account: Account, in interval: DateInterval) -> String {
        let rows = workstreamRows(for: account, in: interval)
        guard !rows.isEmpty else {
            return "No workstream-attributed usage found for \(account.displayLabel(among: [account]))."
        }
        var lines = [
            "Account: \(account.displayLabel(among: [account]))",
            "Provider: \(account.type.displayName)",
            "Period: \(intervalLabel(for: interval))",
        ]
        for row in rows {
            let total = row.inputTokens + row.outputTokens + row.cacheTokens
            lines.append(
                "\(row.workstreamName): in \(row.inputTokens.formatted()) • out \(row.outputTokens.formatted()) • cache \(row.cacheTokens.formatted()) • total \(total.formatted())"
            )
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    static func copySummaryToPasteboard(for account: Account, among accounts: [Account]) -> Bool {
        let text = summaryText(for: account, among: accounts)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    static func copySummaryToPasteboard(for account: Account, among accounts: [Account], in interval: DateInterval) -> Bool {
        let text = summaryText(for: account, among: accounts, in: interval)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    static func copySummaryToPasteboard(for accounts: [Account]) -> Bool {
        let text = summaryText(for: accounts)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    static func copySummaryToPasteboard(for accounts: [Account], in interval: DateInterval) -> Bool {
        let text = summaryText(for: accounts, in: interval)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    static func copyGroupSummaryToPasteboard(
        groupLabel: String,
        accounts: [Account],
        interval: DateInterval
    ) -> Bool {
        let text = groupSummaryText(for: groupLabel, in: accounts, interval: interval)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    static func copyWorkstreamSummaryToPasteboard(for account: Account, in interval: DateInterval) -> Bool {
        let text = workstreamSummaryText(for: account, in: interval)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    static func exportCSV(
        for accounts: [Account],
        filenamePrefix: String = "sage-bar-usage"
    ) throws -> URL {
        try exportCSV(for: accounts, in: nil, filenamePrefix: filenamePrefix)
    }

    static func exportCSV(
        for accounts: [Account],
        in interval: DateInterval?,
        filenamePrefix: String = "sage-bar-usage"
    ) throws -> URL {
        let csv = csvContents(for: accounts, in: interval)
        let stamp = exportTimestamp()
        let suffix = interval.map { "-\(intervalFileLabel(for: $0))" } ?? ""
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("\(filenamePrefix)\(suffix)-\(stamp).csv")
        try AtomicFileWriter.write(Data(csv.utf8), to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        return destination
    }

    static func exportCSV(for account: Account) throws -> URL {
        try exportCSV(for: [account], filenamePrefix: "sage-bar-account-usage")
    }

    static func exportCSV(for account: Account, in interval: DateInterval) throws -> URL {
        try exportCSV(for: [account], in: interval, filenamePrefix: "sage-bar-account-usage")
    }

    static func exportGroupRollupCSV(for accounts: [Account], in interval: DateInterval) throws -> URL {
        let csv = groupRollupCSVContents(for: accounts, in: interval)
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("sage-bar-group-rollup-\(intervalFileLabel(for: interval))-\(exportTimestamp()).csv")
        try AtomicFileWriter.write(Data(csv.utf8), to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        return destination
    }

    static func exportWorkstreamCSV(for account: Account, in interval: DateInterval) throws -> URL {
        let csv = workstreamCSVContents(for: account, in: interval)
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("sage-bar-workstreams-\(account.id.uuidString.prefix(6))-\(intervalFileLabel(for: interval))-\(exportTimestamp()).csv")
        try AtomicFileWriter.write(Data(csv.utf8), to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        return destination
    }

    static func csvContents(for accounts: [Account]) -> String {
        csvContents(for: accounts, in: nil)
    }

    static func csvContents(for accounts: [Account], in interval: DateInterval?) -> String {
        let header = [
            "account_id",
            "account_name",
            "group_label",
            "provider_type",
            "input_tokens",
            "output_tokens",
            "cache_tokens",
            "total_cost_usd",
            "cost_confidence",
            "last_updated",
        ]
        let body = reportRows(for: accounts, in: interval).map(csvLine(for:))
        return ([header.joined(separator: ",")] + body).joined(separator: "\n")
    }

    static func groupRollupCSVContents(for accounts: [Account], in interval: DateInterval) -> String {
        let header = [
            "group_label",
            "account_count",
            "input_tokens",
            "output_tokens",
            "cache_tokens",
            "total_cost_usd",
            "last_updated",
        ]
        let body = groupRollupRows(for: accounts, in: interval).map { row in
            [
                row.groupLabel,
                String(row.accountCount),
                String(row.inputTokens),
                String(row.outputTokens),
                String(row.cacheTokens),
                String(format: "%.4f", row.totalCostUSD),
                row.lastUpdated.map(SharedDateFormatters.iso8601InternetDateTime.string(from:)) ?? "",
            ]
            .map(csvEscape)
            .joined(separator: ",")
        }
        return ([header.joined(separator: ",")] + body).joined(separator: "\n")
    }

    static func workstreamCSVContents(for account: Account, in interval: DateInterval) -> String {
        let header = [
            "account_id",
            "account_name",
            "provider_type",
            "workstream_name",
            "source_count",
            "input_tokens",
            "output_tokens",
            "cache_tokens",
        ]
        let body = workstreamRows(for: account, in: interval).map { row in
            [
                row.accountID.uuidString,
                row.accountName,
                row.providerType.rawValue,
                row.workstreamName,
                String(row.sourceCount),
                String(row.inputTokens),
                String(row.outputTokens),
                String(row.cacheTokens),
            ]
            .map(csvEscape)
            .joined(separator: ",")
        }
        return ([header.joined(separator: ",")] + body).joined(separator: "\n")
    }

    static func costConfidenceLabel(for account: Account, latestSnapshot: UsageSnapshot?) -> String {
        if let latestSnapshot {
            return latestSnapshot.costConfidence == .billingGrade ? "Billing-grade" : "Estimated"
        }
        return (account.type == .anthropicAPI || account.type == .openAIOrg) ? "Billing-grade" : "Estimated"
    }

    private struct AccountUsageAggregate {
        let inputTokens: Int
        let outputTokens: Int
        let cacheTokens: Int
        let totalCostUSD: Double
        let lastUpdated: Date?
        let latestSnapshot: UsageSnapshot?
    }

    private static func accountUsage(for account: Account, in interval: DateInterval?) -> AccountUsageAggregate {
        guard let interval else {
            let latestSnapshot = CacheManager.shared.latest(forAccount: account.id)
            let aggregate = CacheManager.shared.todayAggregate(forAccount: account.id)
            let cacheTokens = aggregate.snapshots.reduce(0) { total, snapshot in
                total + snapshot.cacheReadTokens + snapshot.cacheCreationTokens
            }
            let lastUpdated = CacheManager.shared.loadLastSuccess(forAccount: account.id) ?? latestSnapshot?.timestamp
            return AccountUsageAggregate(
                inputTokens: aggregate.totalInputTokens,
                outputTokens: aggregate.totalOutputTokens,
                cacheTokens: cacheTokens,
                totalCostUSD: aggregate.totalCostUSD,
                lastUpdated: lastUpdated,
                latestSnapshot: latestSnapshot
            )
        }

        let filtered = CacheManager.shared.load()
            .filter { $0.accountId == account.id && interval.contains($0.timestamp) }
        let normalized = normalizeSnapshotsAcrossRange(filtered)
        let latestSnapshot = filtered.max(by: { $0.timestamp < $1.timestamp })
        let lastUpdated = latestSnapshot?.timestamp
            ?? CacheManager.shared.loadLastSuccess(forAccount: account.id)
        return AccountUsageAggregate(
            inputTokens: normalized.reduce(0) { $0 + $1.inputTokens },
            outputTokens: normalized.reduce(0) { $0 + $1.outputTokens },
            cacheTokens: normalized.reduce(0) { $0 + $1.cacheReadTokens + $1.cacheCreationTokens },
            totalCostUSD: normalized.reduce(0) { $0 + $1.totalCostUSD },
            lastUpdated: lastUpdated,
            latestSnapshot: latestSnapshot
        )
    }

    private static func normalizeSnapshotsAcrossRange(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        let grouped = Dictionary(grouping: snapshots) { snapshot in
            Calendar.current.startOfDay(for: snapshot.timestamp)
        }
        return grouped.values
            .flatMap(normalizeDailySnapshots)
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func normalizeDailySnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
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

    private static func isCumulativeSnapshot(_ snapshot: UsageSnapshot) -> Bool {
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

    private static func localSessionUsage(for account: Account, in interval: DateInterval) -> [LocalSessionUsage] {
        switch account.type {
        case .claudeCode:
            return ClaudeCodeLogParser.shared.sessionUsage(in: interval)
        case .codex:
            return CodexLogParser.shared.sessionUsage(in: interval)
        case .gemini:
            return GeminiLogParser.shared.sessionUsage(in: interval)
        default:
            return []
        }
    }

    private static func summaryText(
        for row: UsageReportRow,
        displayName: String,
        interval: DateInterval?
    ) -> String {
        var lines = [
            "Account: \(displayName)",
            "Provider: \(row.providerType.displayName)",
            "Input Tokens: \(row.inputTokens.formatted())",
            "Output Tokens: \(row.outputTokens.formatted())",
            "Cache Tokens: \(row.cacheTokens.formatted())",
            String(format: "Cost Today (USD): %.4f", row.totalCostUSD),
            "Cost Confidence: \(row.costConfidence)",
            "Last Sync: \(row.lastUpdated.map(relativeTimestamp) ?? "Never")",
        ]
        if let interval {
            lines[5] = String(format: "Cost (USD): %.4f", row.totalCostUSD)
            lines.insert("Period: \(intervalLabel(for: interval))", at: 1)
        }
        if let groupLabel = row.groupLabel {
            lines.insert("Group: \(groupLabel)", at: interval == nil ? 1 : 2)
        }
        return lines.joined(separator: "\n")
    }

    private static func csvLine(for row: UsageReportRow) -> String {
        [
            row.accountID.uuidString,
            row.accountName,
            row.groupLabel ?? "",
            row.providerType.rawValue,
            String(row.inputTokens),
            String(row.outputTokens),
            String(row.cacheTokens),
            String(format: "%.4f", row.totalCostUSD),
            row.costConfidence,
            row.lastUpdated.map(SharedDateFormatters.iso8601InternetDateTime.string(from:)) ?? "",
        ]
        .map(csvEscape)
        .joined(separator: ",")
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func relativeTimestamp(_ date: Date) -> String {
        SharedDateFormatters.iso8601InternetDateTime.string(from: date)
    }

    static func normalizedDateInterval(start: Date, end: Date, calendar: Calendar = .current) -> DateInterval {
        let normalizedStart = calendar.startOfDay(for: min(start, end))
        let inclusiveEnd = calendar.startOfDay(for: max(start, end))
        let normalizedEnd = calendar.date(byAdding: .day, value: 1, to: inclusiveEnd) ?? inclusiveEnd
        return DateInterval(start: normalizedStart, end: normalizedEnd)
    }

    static func intervalLabel(for interval: DateInterval) -> String {
        let start = SharedDateFormatters.iso8601FullDate.string(from: interval.start)
        let inclusiveEnd = interval.end.addingTimeInterval(-1)
        let end = SharedDateFormatters.iso8601FullDate.string(from: inclusiveEnd)
        return "\(start) to \(end)"
    }

    private static func intervalFileLabel(for interval: DateInterval) -> String {
        let start = SharedDateFormatters.iso8601FullDate.string(from: interval.start)
        let inclusiveEnd = interval.end.addingTimeInterval(-1)
        let end = SharedDateFormatters.iso8601FullDate.string(from: inclusiveEnd)
        return "\(start)-to-\(end)"
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
