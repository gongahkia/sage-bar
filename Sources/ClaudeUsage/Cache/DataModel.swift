import Foundation

struct ModelUsage: Codable {
    var modelId: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheTokens: Int = 0 // task 89: cache read + creation tokens
    var costUSD: Double
}

struct UsageSnapshot: Codable {
    var accountId: UUID
    var timestamp: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var totalCostUSD: Double
    var modelBreakdown: [ModelUsage]
    var isStale: Bool = false
}

struct DailyAggregate {
    var date: DateComponents // year/month/day
    var snapshots: [UsageSnapshot]
    var totalInputTokens: Int { snapshots.reduce(0) { $0 + $1.inputTokens } }
    var totalOutputTokens: Int { snapshots.reduce(0) { $0 + $1.outputTokens } }
    var totalCostUSD: Double { snapshots.reduce(0) { $0 + $1.totalCostUSD } }
}

struct ForecastSnapshot: Codable {
    var accountId: UUID
    var generatedAt: Date
    var projectedEODCostUSD: Double
    var projectedEOWCostUSD: Double
    var projectedEOMCostUSD: Double
    var burnRatePerHour: Double
}

struct ModelHint: Codable {
    var accountId: UUID
    var date: Date
    var expensiveModelTokens: Int
    var cheaperAlternativeExists: Bool
    var estimatedSavingsUSD: Double
    var recommendedModel: String
}
