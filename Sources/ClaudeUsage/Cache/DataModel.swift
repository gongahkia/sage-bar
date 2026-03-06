import Foundation

public enum CostConfidence: String, Codable, Equatable {
    case billingGrade
    case estimated
}

public struct ModelUsage: Codable, Equatable {
    public var modelId: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheTokens: Int
    public var costUSD: Double
    enum CodingKeys: String, CodingKey {
        case modelId, inputTokens, outputTokens, cacheTokens, costUSD
    }
    public init(modelId: String, inputTokens: Int, outputTokens: Int, cacheTokens: Int = 0, costUSD: Double) {
        self.modelId = modelId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.costUSD = costUSD
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try c.decode(String.self, forKey: .modelId)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheTokens = try c.decodeIfPresent(Int.self, forKey: .cacheTokens) ?? 0
        costUSD = try c.decode(Double.self, forKey: .costUSD)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheTokens, forKey: .cacheTokens)
        try c.encode(costUSD, forKey: .costUSD)
    }
}

public struct UsageSnapshot: Codable, Equatable {
    public var accountId: UUID
    public var timestamp: Date
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var totalCostUSD: Double
    public var modelBreakdown: [ModelUsage]
    public var isStale: Bool
    public var costConfidence: CostConfidence
    enum CodingKeys: String, CodingKey {
        case accountId, timestamp, inputTokens, outputTokens
        case cacheCreationTokens, cacheReadTokens, totalCostUSD
        case modelBreakdown, isStale, costConfidence
    }
    public init(
        accountId: UUID, timestamp: Date, inputTokens: Int, outputTokens: Int,
        cacheCreationTokens: Int, cacheReadTokens: Int, totalCostUSD: Double,
        modelBreakdown: [ModelUsage], isStale: Bool = false,
        costConfidence: CostConfidence = .billingGrade
    ) {
        self.accountId = accountId
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalCostUSD = totalCostUSD
        self.modelBreakdown = modelBreakdown
        self.isStale = isStale
        self.costConfidence = costConfidence
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try c.decode(Int.self, forKey: .cacheCreationTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        totalCostUSD = try c.decode(Double.self, forKey: .totalCostUSD)
        modelBreakdown = try c.decode([ModelUsage].self, forKey: .modelBreakdown)
        isStale = try c.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
        costConfidence = try c.decodeIfPresent(CostConfidence.self, forKey: .costConfidence)
            ?? Self.inferLegacyCostConfidence(modelBreakdown: modelBreakdown)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(totalCostUSD, forKey: .totalCostUSD)
        try c.encode(modelBreakdown, forKey: .modelBreakdown)
        try c.encode(isStale, forKey: .isStale)
        try c.encode(costConfidence, forKey: .costConfidence)
    }
    private static func inferLegacyCostConfidence(modelBreakdown: [ModelUsage]) -> CostConfidence {
        let estimatedModelIDs: Set<String> = [
            "claude-ai-web", "claude-code-local", "codex-local",
            "gemini-local", "windsurf-enterprise", "copilot-metrics",
        ]
        if modelBreakdown.contains(where: { estimatedModelIDs.contains($0.modelId) }) {
            return .estimated
        }
        return .billingGrade
    }
}

public struct ForecastSnapshot: Codable, Equatable {
    public var accountId: UUID
    public var generatedAt: Date
    public var projectedEODCostUSD: Double
    public var projectedEOWCostUSD: Double
    public var projectedEOMCostUSD: Double
    public var burnRatePerHour: Double
    public init(
        accountId: UUID, generatedAt: Date, projectedEODCostUSD: Double,
        projectedEOWCostUSD: Double, projectedEOMCostUSD: Double, burnRatePerHour: Double
    ) {
        self.accountId = accountId
        self.generatedAt = generatedAt
        self.projectedEODCostUSD = projectedEODCostUSD
        self.projectedEOWCostUSD = projectedEOWCostUSD
        self.projectedEOMCostUSD = projectedEOMCostUSD
        self.burnRatePerHour = burnRatePerHour
    }
}

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
