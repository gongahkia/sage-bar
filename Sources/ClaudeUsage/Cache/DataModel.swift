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
    enum SavingsConfidence: String, Codable {
        case measured
        case profileEstimated
        case heuristicEstimated
    }

    var accountId: UUID
    var date: Date
    var expensiveModelTokens: Int
    var cheaperAlternativeExists: Bool
    var estimatedSavingsUSD: Double
    var recommendedModel: String
    var savingsConfidence: SavingsConfidence

    enum CodingKeys: String, CodingKey {
        case accountId
        case date
        case expensiveModelTokens
        case cheaperAlternativeExists
        case estimatedSavingsUSD
        case recommendedModel
        case savingsConfidence
    }

    init(
        accountId: UUID,
        date: Date,
        expensiveModelTokens: Int,
        cheaperAlternativeExists: Bool,
        estimatedSavingsUSD: Double,
        recommendedModel: String,
        savingsConfidence: SavingsConfidence
    ) {
        self.accountId = accountId
        self.date = date
        self.expensiveModelTokens = expensiveModelTokens
        self.cheaperAlternativeExists = cheaperAlternativeExists
        self.estimatedSavingsUSD = estimatedSavingsUSD
        self.recommendedModel = recommendedModel
        self.savingsConfidence = savingsConfidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        date = try c.decode(Date.self, forKey: .date)
        expensiveModelTokens = try c.decode(Int.self, forKey: .expensiveModelTokens)
        cheaperAlternativeExists = try c.decode(Bool.self, forKey: .cheaperAlternativeExists)
        estimatedSavingsUSD = try c.decode(Double.self, forKey: .estimatedSavingsUSD)
        recommendedModel = try c.decode(String.self, forKey: .recommendedModel)
        savingsConfidence = try c.decodeIfPresent(SavingsConfidence.self, forKey: .savingsConfidence) ?? .measured
    }
}

struct AnthropicIngestionCursor: Codable {
    var lastStartTime: String
    var lastModel: String
}
