import Foundation
import AppIntents

// MARK: – App Entities

struct UsageRecord: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Usage Record"
    static let defaultQuery = UsageRecordQuery()

    var id: UUID
    var accountName: String
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
    var lastUpdated: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(accountName): \(String(format: "$%.4f", costUSD))")
    }
}

struct SageBarAccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sage Bar Account"
    static let defaultQuery = SageBarAccountQuery()

    var id: UUID
    var name: String
    var groupLabel: String?
    var providerName: String

    var displayRepresentation: DisplayRepresentation {
        let subtitle = groupLabel.map { "\($0) • \(providerName)" } ?? providerName
        return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }
}

struct CurrentUsageResult: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Current Usage"
    static let defaultQuery = CurrentUsageResultQuery()

    var id: UUID
    var accountName: String
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCostUSD: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(accountName): \(String(format: "$%.4f", totalCostUSD))")
    }
}

struct UsageRecordQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [UsageRecord] {
        let accounts = UsageAccessService.activeAccounts().filter { identifiers.contains($0.id) }
        return await records(for: accounts)
    }

    func suggestedEntities() async throws -> [UsageRecord] {
        await records(for: UsageAccessService.activeAccounts())
    }

    private func records(for accounts: [Account]) async -> [UsageRecord] {
        var records: [UsageRecord] = []
        for account in accounts {
            let payload = await UsageAccessService.currentUsage(for: account)
            records.append(
                UsageRecord(
                    id: payload.accountID,
                    accountName: payload.accountName,
                    inputTokens: payload.totalInputTokens,
                    outputTokens: payload.totalOutputTokens,
                    costUSD: payload.totalCostUSD,
                    lastUpdated: payload.lastUpdated ?? Date()
                )
            )
        }
        return records
    }
}

struct SageBarAccountQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [SageBarAccountEntity] {
        UsageAccessService.activeAccounts()
            .filter { identifiers.contains($0.id) }
            .map(entity(for:))
    }

    func suggestedEntities() async throws -> [SageBarAccountEntity] {
        UsageAccessService.activeAccounts().map(entity(for:))
    }

    private func entity(for account: Account) -> SageBarAccountEntity {
        SageBarAccountEntity(
            id: account.id,
            name: account.displayLabel(among: UsageAccessService.activeAccounts()),
            groupLabel: account.trimmedGroupLabel,
            providerName: account.type.displayName
        )
    }
}

struct CurrentUsageResultQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [CurrentUsageResult] {
        let accounts = UsageAccessService.activeAccounts().filter { identifiers.contains($0.id) }
        return await results(for: accounts)
    }

    func suggestedEntities() async throws -> [CurrentUsageResult] {
        let account = UsageAccessService.preferredAccount()
        guard let account else { return [] }
        return await results(for: [account])
    }

    private func results(for accounts: [Account]) async -> [CurrentUsageResult] {
        var results: [CurrentUsageResult] = []
        for account in accounts {
            let payload = await UsageAccessService.currentUsage(for: account)
            results.append(
                CurrentUsageResult(
                    id: payload.accountID,
                    accountName: payload.accountName,
                    totalInputTokens: payload.totalInputTokens,
                    totalOutputTokens: payload.totalOutputTokens,
                    totalCostUSD: payload.totalCostUSD
                )
            )
        }
        return results
    }
}

// MARK: – Intents

struct GetTodayUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Sage Bar Usage Today"
    static let description = IntentDescription("Returns today's usage data for all active accounts.")

    func perform() async throws -> some ReturnsValue<[UsageRecord]> {
        let accounts = UsageAccessService.activeAccounts()
        let records = try await UsageRecordQuery().suggestedEntities()
        if records.isEmpty, accounts.isEmpty {
            throw APIError.unsupported
        }
        return .result(value: records)
    }
}

struct GetCurrentUsage: AppIntent {
    static let title: LocalizedStringResource = "Get Current Usage"
    static let description = IntentDescription("Returns current usage for the selected account.")

    @Parameter(title: "Account")
    var account: SageBarAccountEntity?

    func perform() async throws -> some ReturnsValue<CurrentUsageResult> {
        let resolvedAccount = UsageAccessService.resolveAccount(identifierOrName: account?.id.uuidString)
        guard let resolvedAccount else {
            throw APIError.unsupported
        }
        let payload = await UsageAccessService.currentUsage(for: resolvedAccount)
        return .result(
            value: CurrentUsageResult(
                id: payload.accountID,
                accountName: payload.accountName,
                totalInputTokens: payload.totalInputTokens,
                totalOutputTokens: payload.totalOutputTokens,
                totalCostUSD: payload.totalCostUSD
            )
        )
    }
}

struct TriggerPoll: AppIntent {
    static let title: LocalizedStringResource = "Trigger Poll"
    static let description = IntentDescription("Triggers an immediate poll and returns true if no error occurred.")

    @MainActor
    func perform() async throws -> some ReturnsValue<Bool> {
        await PollingService.shared.pollOnce()
        return .result(value: PollingService.shared.lastFetchError == nil)
    }
}

struct GetForecastIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Sage Bar Forecast"
    static let description = IntentDescription("Returns projected spend for the selected account.")

    @Parameter(title: "Account")
    var account: SageBarAccountEntity?

    func perform() async throws -> some ReturnsValue<String> {
        guard let resolvedAccount = UsageAccessService.resolveAccount(identifierOrName: account?.id.uuidString) else {
            return .result(value: "No forecast data available.")
        }
        return .result(value: await UsageAccessService.forecastSummary(for: resolvedAccount))
    }
}

struct GetUsageSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Usage Summary"
    static let description = IntentDescription("Returns a shareable usage summary for one account or all active accounts.")

    @Parameter(title: "Account")
    var account: SageBarAccountEntity?

    func perform() async throws -> some ReturnsValue<String> {
        let resolvedAccount = UsageAccessService.resolveAccount(identifierOrName: account?.id.uuidString)
        return .result(value: UsageAccessService.usageSummary(for: resolvedAccount))
    }
}

struct CopyUsageSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Usage Summary"
    static let description = IntentDescription("Copies a usage summary for the selected account or all active accounts to the clipboard.")

    @Parameter(title: "Account")
    var account: SageBarAccountEntity?

    @MainActor
    func perform() async throws -> some ReturnsValue<Bool> {
        let resolvedAccount = UsageAccessService.resolveAccount(identifierOrName: account?.id.uuidString)
        return .result(value: UsageAccessService.copyUsageSummary(account: resolvedAccount))
    }
}

struct ExportUsageCSVIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Usage CSV"
    static let description = IntentDescription("Exports a CSV for the selected account or all active accounts and returns the destination path.")

    @Parameter(title: "Account")
    var account: SageBarAccountEntity?

    @MainActor
    func perform() async throws -> some ReturnsValue<String> {
        let resolvedAccount = UsageAccessService.resolveAccount(identifierOrName: account?.id.uuidString)
        let url = try UsageAccessService.exportUsageCSV(account: resolvedAccount)
        return .result(value: url.path)
    }
}

struct SageBarShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetTodayUsageIntent(),
            phrases: [
                "Get today's Sage Bar usage in \(.applicationName)",
                "Show my Sage Bar totals in \(.applicationName)",
            ],
            shortTitle: "Today's Usage",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: GetUsageSummaryIntent(),
            phrases: [
                "Get a Sage Bar summary in \(.applicationName)",
                "Show account usage summary in \(.applicationName)",
            ],
            shortTitle: "Usage Summary",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: CopyUsageSummaryIntent(),
            phrases: [
                "Copy my Sage Bar summary in \(.applicationName)",
                "Copy account usage summary in \(.applicationName)",
            ],
            shortTitle: "Copy Summary",
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: ExportUsageCSVIntent(),
            phrases: [
                "Export Sage Bar CSV in \(.applicationName)",
                "Export account usage CSV in \(.applicationName)",
            ],
            shortTitle: "Export CSV",
            systemImageName: "square.and.arrow.up"
        )
    }
}
