import Foundation

struct ModelOptimizerAnalyzer {
    static func analyze(breakdown: [ModelUsage], accountId: UUID, config: ModelOptimizerConfig) -> ModelHint? {
        guard config.enabled else { return nil }
        let expensive = breakdown.filter { m in
            m.modelId.contains("opus") || m.modelId.contains("sonnet")
        }
        guard !expensive.isEmpty else { return nil }
        let expensiveTokens = expensive.reduce(0) { $0 + $1.outputTokens }
        guard expensiveTokens < config.cheapThresholdTokens else { return nil }

        let currentCostTotal = expensive.reduce(0) { $0 + $1.costUSD }
        let currentInputTotal = expensive.reduce(0) { $0 + $1.inputTokens }
        let currentOutputTotal = expensive.reduce(0) { $0 + $1.outputTokens }

        // estimate cost using haiku pricing
        let haikuPrice = AnthropicAPIClient.pricingConstants["claude-3-haiku"] ?? (0.25, 1.25)
        let haikuCost = Double(currentInputTotal) / 1_000_000 * haikuPrice.inputPer1M
                      + Double(currentOutputTotal) / 1_000_000 * haikuPrice.outputPer1M
        let savings = currentCostTotal - haikuCost

        guard savings > 0 else { return nil }

        return ModelHint(
            accountId: accountId,
            date: Date(),
            expensiveModelTokens: expensiveTokens,
            cheaperAlternativeExists: true,
            estimatedSavingsUSD: savings,
            recommendedModel: "claude-3-haiku"
        )
    }
}
