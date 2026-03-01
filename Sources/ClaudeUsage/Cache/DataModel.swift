import Foundation
import ClaudeUsageCore

typealias CostConfidence = ClaudeUsageCore.CostConfidence
typealias ModelUsage = ClaudeUsageCore.ModelUsage
typealias UsageSnapshot = ClaudeUsageCore.UsageSnapshot
typealias ForecastSnapshot = ClaudeUsageCore.ForecastSnapshot

struct DailyAggregate {
    var date: DateComponents // year/month/day
    var snapshots: [UsageSnapshot]
    var totalInputTokens: Int { snapshots.reduce(0) { $0 + $1.inputTokens } }
    var totalOutputTokens: Int { snapshots.reduce(0) { $0 + $1.outputTokens } }
    var totalCostUSD: Double { snapshots.reduce(0) { $0 + $1.totalCostUSD } }
}

enum CacheSchema {
    static let currentVersion = 2
}

struct UsageCachePayload: Codable {
    var schemaVersion: Int
    var snapshots: [UsageSnapshot]

    init(schemaVersion: Int = CacheSchema.currentVersion, snapshots: [UsageSnapshot]) {
        self.schemaVersion = schemaVersion
        self.snapshots = snapshots
    }
}

struct ForecastCachePayload: Codable {
    var schemaVersion: Int
    var forecasts: [ForecastSnapshot]

    init(schemaVersion: Int = CacheSchema.currentVersion, forecasts: [ForecastSnapshot]) {
        self.schemaVersion = schemaVersion
        self.forecasts = forecasts
    }
}

struct ModelHint: Codable {
    var accountId: UUID
    var date: Date
    var expensiveModelTokens: Int
    var cheaperAlternativeExists: Bool
    var estimatedSavingsUSD: Double
    var recommendedModel: String
}

struct AnthropicIngestionCursor: Codable {
    var lastStartTime: String
    var lastModel: String
}
