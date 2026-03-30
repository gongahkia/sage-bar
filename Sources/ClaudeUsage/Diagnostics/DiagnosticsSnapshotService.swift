import Foundation

struct DiagnosticsAppMetadata: Codable {
    var bundleIdentifier: String
    var shortVersion: String
    var buildVersion: String
    var configSchemaVersion: Int
    var sharedContainerPath: String
    var configPath: String
    var errorLogPath: String
}

struct DiagnosticsTotals: Codable {
    var accountCount: Int
    var activeAccountCount: Int
    var accountCountByProvider: [String: Int]
}

struct DiagnosticsAccountSnapshot: Codable {
    var accountID: String
    var name: String
    var providerType: String
    var providerDisplayName: String
    var isActive: Bool
    var groupLabel: String?
    var localDataPath: String?
    var hasWorkstreamRules: Bool
    var fetchErrorMessage: String?
    var fetchErrorUpdatedAt: Date?
    var providerHealthScore: Double?
}

struct DiagnosticsPollingSnapshot: Codable {
    var isPolling: Bool
    var lastPollDate: Date?
    var lastFetchError: String?
    var lastPollSuccessCount: Int
    var lastPollFailureCount: Int
    var pollDurationP50Ms: Int
    var pollDurationP90Ms: Int
    var pollSkipCountsByReason: [String: Int]
}

struct DiagnosticsParserMetricSnapshot: Codable {
    var parser: String
    var runs: Int
    var filesScanned: Int
    var linesParsed: Int
    var linesRejected: Int
    var bytesRead: Int
    var cpuTimeMs: Int
    var wallTimeMs: Int
}

struct DiagnosticsSnapshot: Codable {
    var generatedAt: Date
    var app: DiagnosticsAppMetadata
    var totals: DiagnosticsTotals
    var polling: DiagnosticsPollingSnapshot
    var accounts: [DiagnosticsAccountSnapshot]
    var parserMetrics: [DiagnosticsParserMetricSnapshot]
    var recentErrors: [String]
}

enum DiagnosticsSnapshotService {
    static func snapshot(
        config: Config = ConfigManager.shared.load(),
        now: Date = Date(),
        maxErrorLines: Int = 120
    ) async -> DiagnosticsSnapshot {
        let sortedAccounts = Account.sortedForDisplay(config.accounts)
        let activeAccounts = sortedAccounts.filter(\.isActive)
        let accountCounts = Dictionary(grouping: sortedAccounts, by: { $0.type.rawValue })
            .mapValues(\.count)

        let accountSnapshots = await MainActor.run {
            sortedAccounts.map { account in
                DiagnosticsAccountSnapshot(
                    accountID: account.id.uuidString,
                    name: account.trimmedName.isEmpty ? account.type.displayName : account.trimmedName,
                    providerType: account.type.rawValue,
                    providerDisplayName: account.type.displayName,
                    isActive: account.isActive,
                    groupLabel: account.trimmedGroupLabel,
                    localDataPath: account.trimmedLocalDataPath,
                    hasWorkstreamRules: account.hasWorkstreamRules,
                    fetchErrorMessage: PollingService.shared.fetchErrorMessage(for: account.id),
                    fetchErrorUpdatedAt: PollingService.shared.fetchErrorUpdatedAt(for: account.id),
                    providerHealthScore: PollingService.shared.providerHealthScore(for: account.id)
                )
            }
        }

        let pollingSnapshot = await MainActor.run {
            DiagnosticsPollingSnapshot(
                isPolling: PollingService.shared.isPolling,
                lastPollDate: PollingService.shared.lastPollDate,
                lastFetchError: PollingService.shared.lastFetchError,
                lastPollSuccessCount: PollingService.shared.lastPollSuccessCount,
                lastPollFailureCount: PollingService.shared.lastPollFailureCount,
                pollDurationP50Ms: PollingService.shared.pollDurationP50Ms,
                pollDurationP90Ms: PollingService.shared.pollDurationP90Ms,
                pollSkipCountsByReason: Dictionary(
                    uniqueKeysWithValues: PollingService.shared
                        .pollSkipTotalsOrdered()
                        .map { ($0.0.rawValue, $0.1) }
                )
            )
        }

        let parserSnapshots = ParserMetricsStore.shared.snapshot().map {
            DiagnosticsParserMetricSnapshot(
                parser: $0.parser,
                runs: $0.runs,
                filesScanned: $0.filesScanned,
                linesParsed: $0.linesParsed,
                linesRejected: $0.linesRejected,
                bytesRead: $0.bytesRead,
                cpuTimeMs: $0.cpuTimeMs,
                wallTimeMs: $0.wallTimeMs
            )
        }

        let clampedErrorLines = min(max(maxErrorLines, 1), 1_000)
        let errors = ErrorLogger.shared.readLast(clampedErrorLines)

        return DiagnosticsSnapshot(
            generatedAt: now,
            app: appMetadata(config: config),
            totals: DiagnosticsTotals(
                accountCount: sortedAccounts.count,
                activeAccountCount: activeAccounts.count,
                accountCountByProvider: accountCounts
            ),
            polling: pollingSnapshot,
            accounts: accountSnapshots,
            parserMetrics: parserSnapshots,
            recentErrors: errors
        )
    }

    static func snapshotJSONString(
        config: Config = ConfigManager.shared.load(),
        maxErrorLines: Int = 120,
        prettyPrinted: Bool = true
    ) async -> String {
        let diagnostics = await snapshot(config: config, maxErrorLines: maxErrorLines)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]

        do {
            let data = try encoder.encode(diagnostics)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            ErrorLogger.shared.log(
                "Diagnostics snapshot encoding produced non-UTF8 payload",
                level: "WARN"
            )
            return "{\"error\":\"diagnostics encoding produced non-utf8 payload\"}"
        } catch {
            ErrorLogger.shared.log(
                "Diagnostics snapshot encoding failed: \(error.localizedDescription)",
                level: "WARN"
            )
            return "{\"error\":\"diagnostics snapshot encoding failed\"}"
        }
    }

    private static func appMetadata(config: Config) -> DiagnosticsAppMetadata {
        let bundle = Bundle.main
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home
            .appendingPathComponent(".config")
            .appendingPathComponent("claude-usage")
            .appendingPathComponent("config.toml")
        let errorLogPath = home
            .appendingPathComponent(".claude-usage")
            .appendingPathComponent("errors.log")

        return DiagnosticsAppMetadata(
            bundleIdentifier: bundle.bundleIdentifier ?? AppConstants.bundleIdentifier,
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            configSchemaVersion: config.schemaVersion,
            sharedContainerPath: AppConstants.sharedContainerURL.path,
            configPath: configPath.path,
            errorLogPath: errorLogPath.path
        )
    }
}
