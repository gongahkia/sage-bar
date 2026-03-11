import Foundation

struct CurrentUsagePayload: Equatable {
    let accountID: UUID
    let accountName: String
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCostUSD: Double
    let lastUpdated: Date?
}

enum UsageAccessService {
    static func activeAccounts(config: Config = ConfigManager.shared.load()) -> [Account] {
        Account.activeAccounts(in: config)
    }

    static func preferredAccount(
        config: Config = ConfigManager.shared.load(),
        userDefaults: UserDefaults = .standard
    ) -> Account? {
        Account.preferredAccount(from: activeAccounts(config: config), userDefaults: userDefaults)
    }

    static func resolveAccount(
        identifierOrName: String?,
        config: Config = ConfigManager.shared.load(),
        userDefaults: UserDefaults = .standard
    ) -> Account? {
        let accounts = activeAccounts(config: config)
        guard let identifierOrName = identifierOrName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifierOrName.isEmpty else {
            return Account.preferredAccount(from: accounts, userDefaults: userDefaults)
        }
        if let uuid = UUID(uuidString: identifierOrName),
           let match = accounts.first(where: { $0.id == uuid }) {
            return match
        }
        let normalized = identifierOrName.lowercased()
        if let exactName = accounts.first(where: { $0.trimmedName.lowercased() == normalized }) {
            return exactName
        }
        if let displayName = accounts.first(where: { $0.displayLabel(among: accounts).lowercased() == normalized }) {
            return displayName
        }
        return accounts.first(where: { ($0.trimmedGroupLabel?.lowercased().contains(normalized)) == true })
    }

    static func currentUsage(
        for account: Account,
        config: Config = ConfigManager.shared.load()
    ) async -> CurrentUsagePayload {
        async let aggregate = CacheManager.shared.todayAggregateAsync(forAccount: account.id)
        async let lastSuccess = CacheManager.shared.loadLastSuccessAsync(forAccount: account.id)
        async let latestSnapshot = CacheManager.shared.latestAsync(forAccount: account.id)
        let agg = await aggregate
        let resolvedLastSuccess = await lastSuccess
        let resolvedLatestSnapshot = await latestSnapshot
        let lastUpdated = resolvedLastSuccess ?? resolvedLatestSnapshot?.timestamp
        return CurrentUsagePayload(
            accountID: account.id,
            accountName: account.displayLabel(among: activeAccounts(config: config)),
            totalInputTokens: agg.totalInputTokens,
            totalOutputTokens: agg.totalOutputTokens,
            totalCostUSD: agg.totalCostUSD,
            lastUpdated: lastUpdated
        )
    }

    static func forecastSummary(for account: Account) async -> String {
        guard let forecast = await CacheManager.shared.latestForecastAsync(forAccount: account.id) else {
            return "No forecast data available."
        }
        return String(
            format: "EOD: $%.2f  EOW: $%.2f  EOM: $%.2f",
            forecast.projectedEODCostUSD,
            forecast.projectedEOWCostUSD,
            forecast.projectedEOMCostUSD
        )
    }

    static func usageSummary(for account: Account?) -> String {
        if let account {
            return UsageReportingService.summaryText(for: account, among: activeAccounts())
        }
        return UsageReportingService.summaryText(for: activeAccounts())
    }

    static func usageSummary(for account: Account?, in interval: DateInterval) -> String {
        if let account {
            return UsageReportingService.summaryText(for: account, among: activeAccounts(), in: interval)
        }
        return UsageReportingService.summaryText(for: activeAccounts(), in: interval)
    }

    static func groupSummary(groupLabel: String, in interval: DateInterval) -> String {
        UsageReportingService.groupSummaryText(for: groupLabel, in: activeAccounts(), interval: interval)
    }

    @MainActor
    static func copyUsageSummary(account: Account?, in interval: DateInterval? = nil) -> Bool {
        let accounts = activeAccounts()
        if let account {
            if let interval {
                return UsageReportingService.copySummaryToPasteboard(for: account, among: accounts, in: interval)
            }
            return UsageReportingService.copySummaryToPasteboard(for: account, among: accounts)
        }
        if let interval {
            return UsageReportingService.copySummaryToPasteboard(for: accounts, in: interval)
        }
        return UsageReportingService.copySummaryToPasteboard(for: accounts)
    }

    @MainActor
    static func exportUsageCSV(account: Account?, in interval: DateInterval? = nil) throws -> URL {
        if let account {
            if let interval {
                return try UsageReportingService.exportCSV(for: account, in: interval)
            }
            return try UsageReportingService.exportCSV(for: account)
        }
        return try UsageReportingService.exportCSV(for: activeAccounts(), in: interval, filenamePrefix: "sage-bar-shortcuts")
    }
}
