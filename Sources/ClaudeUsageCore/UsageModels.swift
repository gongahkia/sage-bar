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

    public init(modelId: String, inputTokens: Int, outputTokens: Int, cacheTokens: Int = 0, costUSD: Double) {
        self.modelId = modelId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.costUSD = costUSD
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

    public init(
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
            "claude-ai-web",
            "claude-code-local",
            "codex-local",
            "gemini-local",
            "windsurf-enterprise",
            "copilot-metrics",
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
        accountId: UUID,
        generatedAt: Date,
        projectedEODCostUSD: Double,
        projectedEOWCostUSD: Double,
        projectedEOMCostUSD: Double,
        burnRatePerHour: Double
    ) {
        self.accountId = accountId
        self.generatedAt = generatedAt
        self.projectedEODCostUSD = projectedEODCostUSD
        self.projectedEOWCostUSD = projectedEOWCostUSD
        self.projectedEOMCostUSD = projectedEOMCostUSD
        self.burnRatePerHour = burnRatePerHour
    }
}
