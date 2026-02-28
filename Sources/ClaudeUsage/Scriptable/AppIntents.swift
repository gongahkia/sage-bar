import Foundation
import AppIntents

// MARK: – GetTodayUsageIntent

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

struct UsageRecordQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [UsageRecord] { [] }
    func suggestedEntities() async throws -> [UsageRecord] { [] }
}

struct GetTodayUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Claude Usage Today"
    static let description = IntentDescription("Returns today's Claude usage data for all active accounts.")

    func perform() async throws -> some ReturnsValue<[UsageRecord]> {
        let config = ConfigManager.shared.load()
        let records = config.accounts.filter { $0.isActive }.compactMap { account -> UsageRecord? in
            let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
            return UsageRecord(
                id: account.id,
                accountName: account.name,
                inputTokens: agg.totalInputTokens,
                outputTokens: agg.totalOutputTokens,
                costUSD: agg.totalCostUSD,
                lastUpdated: agg.snapshots.last?.timestamp ?? Date()
            )
        }
        return .result(value: records)
    }
}

// MARK: – Task 93: GetCurrentUsage

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

struct CurrentUsageResultQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [CurrentUsageResult] { [] }
    func suggestedEntities() async throws -> [CurrentUsageResult] { [] }
}

struct GetCurrentUsage: AppIntent {
    static let title: LocalizedStringResource = "Get Current Usage"
    static let description = IntentDescription("Returns current usage for the first active account.")

    @MainActor
    func perform() async throws -> some ReturnsValue<CurrentUsageResult> {
        let config = ConfigManager.shared.load()
        guard let account = config.accounts.first(where: { $0.isActive }) else {
            throw APIError.unsupported
        }
        let agg = CacheManager.shared.todayAggregate(forAccount: account.id)
        return .result(value: CurrentUsageResult(
            id: account.id,
            accountName: account.name,
            totalInputTokens: agg.totalInputTokens,
            totalOutputTokens: agg.totalOutputTokens,
            totalCostUSD: agg.totalCostUSD
        ))
    }
}

// MARK: – Task 94: TriggerPoll

struct TriggerPoll: AppIntent {
    static let title: LocalizedStringResource = "Trigger Poll"
    static let description = IntentDescription("Triggers an immediate poll and returns true if no error occurred.")

    @MainActor
    func perform() async throws -> some ReturnsValue<Bool> {
        await PollingService.shared.pollOnce()
        return .result(value: PollingService.shared.lastFetchError == nil)
    }
}

// MARK: –

struct GetForecastIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Claude Spend Forecast"
    static let description = IntentDescription("Returns projected Claude spend for EOD, EOW, EOM.")

    func perform() async throws -> some ReturnsValue<String> {
        let config = ConfigManager.shared.load()
        guard let account = config.accounts.first(where: { $0.isActive }),
              let f = CacheManager.shared.latestForecast(forAccount: account.id) else {
            return .result(value: "No forecast data available.")
        }
        return .result(value: String(format: "EOD: $%.2f  EOW: $%.2f  EOM: $%.2f",
                                     f.projectedEODCostUSD, f.projectedEOWCostUSD, f.projectedEOMCostUSD))
    }
}
