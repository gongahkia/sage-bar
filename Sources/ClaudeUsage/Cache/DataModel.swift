import Foundation

enum CostConfidence: String, Codable {
    case billingGrade
    case estimated
}

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
    var costConfidence: CostConfidence = .billingGrade

    enum CodingKeys: String, CodingKey {
        case accountId
        case timestamp
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case totalCostUSD
        case modelBreakdown
        case isStale
        case costConfidence
    }

    init(
        accountId: UUID,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        totalCostUSD: Double,
        modelBreakdown: [ModelUsage],
        isStale: Bool = false,
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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
        let estimatedModelIDs: Set<String> = ["claude-ai-web", "claude-code-local"]
        if modelBreakdown.contains(where: { estimatedModelIDs.contains($0.modelId) }) {
            return .estimated
        }
        return .billingGrade
    }
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

struct AnthropicIngestionCursor: Codable {
    var lastStartTime: String
    var lastModel: String
}
