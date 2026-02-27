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
