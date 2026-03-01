import Foundation

struct ModelOptimizerAnalyzer {
    private enum ProviderFamily {
        case claude
        case codex
        case gemini
    }

    private struct Pricing {
        let inputPer1M: Double
        let outputPer1M: Double
    }

    private static let fallbackCurrentPricingByFamily: [ProviderFamily: Pricing] = [
        .claude: Pricing(inputPer1M: 3.00, outputPer1M: 15.00),
        .codex: Pricing(inputPer1M: 2.00, outputPer1M: 8.00),
        .gemini: Pricing(inputPer1M: 1.25, outputPer1M: 5.00),
    ]

    private static let fallbackCheaperPricingByFamily: [ProviderFamily: Pricing] = [
        .claude: Pricing(inputPer1M: 0.25, outputPer1M: 1.25),
        .codex: Pricing(inputPer1M: 0.15, outputPer1M: 0.60),
        .gemini: Pricing(inputPer1M: 0.10, outputPer1M: 0.40),
    ]

    private static let recommendedModelByFamily: [ProviderFamily: String] = [
        .claude: "claude-3-haiku",
        .codex: "gpt-4o-mini",
        .gemini: "gemini-2.0-flash",
    ]

    static func analyze(breakdown: [ModelUsage], accountId: UUID, config: ModelOptimizerConfig) -> ModelHint? {
        guard config.enabled else { return nil }
        let expensive = breakdown.filter { classifyFamily(for: $0.modelId) != nil }
        guard !expensive.isEmpty else { return nil }
        let family = dominantFamily(in: expensive)
        let familyExpensive = expensive.filter { usage in
            classifyFamily(for: usage.modelId) == family
        }
        guard !familyExpensive.isEmpty else { return nil }

        let expensiveTokens = familyExpensive.reduce(0) { $0 + $1.outputTokens }
        guard expensiveTokens < config.cheapThresholdTokens else { return nil }

        let currentInputTotal = familyExpensive.reduce(0) { $0 + $1.inputTokens }
        let currentOutputTotal = familyExpensive.reduce(0) { $0 + $1.outputTokens }
        let measuredCurrentCost = familyExpensive.reduce(0) { $0 + max(0, $1.costUSD) }

        guard let currentPricing = fallbackCurrentPricingByFamily[family],
              let cheaperPricing = fallbackCheaperPricingByFamily[family],
              let recommendedModel = recommendedModelByFamily[family] else { return nil }

        let estimatedCurrentCost = estimatedCostUSD(
            inputTokens: currentInputTotal,
            outputTokens: currentOutputTotal,
            pricing: currentPricing
        )
        let currentCostTotal = measuredCurrentCost > 0 ? measuredCurrentCost : estimatedCurrentCost
        let cheaperCost = estimatedCostUSD(
            inputTokens: currentInputTotal,
            outputTokens: currentOutputTotal,
            pricing: cheaperPricing
        )
        let savings = currentCostTotal - cheaperCost

        guard savings > 0 else { return nil }

        return ModelHint(
            accountId: accountId,
            date: Date(),
            expensiveModelTokens: expensiveTokens,
            cheaperAlternativeExists: true,
            estimatedSavingsUSD: savings,
            recommendedModel: recommendedModel
        )
    }

    private static func dominantFamily(in usage: [ModelUsage]) -> ProviderFamily {
        var tokenCountByFamily: [ProviderFamily: Int] = [:]
        for model in usage {
            guard let family = classifyFamily(for: model.modelId) else { continue }
            tokenCountByFamily[family, default: 0] += max(0, model.outputTokens)
        }
        return tokenCountByFamily.max(by: { $0.value < $1.value })?.key ?? .claude
    }

    private static func classifyFamily(for modelId: String) -> ProviderFamily? {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if normalized == "claude-code-local"
            || normalized.contains("claude-opus")
            || normalized.contains("claude-sonnet")
            || normalized.contains("opus")
            || normalized.contains("sonnet") {
            return .claude
        }
        if normalized == "codex-local"
            || normalized.hasPrefix("gpt-4")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.contains("codex") {
            return .codex
        }
        if normalized == "gemini-local"
            || normalized.contains("gemini-2.5-pro")
            || normalized.contains("gemini-1.5-pro")
            || normalized.contains("gemini-pro") {
            return .gemini
        }
        return nil
    }

    private static func estimatedCostUSD(inputTokens: Int, outputTokens: Int, pricing: Pricing) -> Double {
        Double(max(0, inputTokens)) / 1_000_000.0 * pricing.inputPer1M
        + Double(max(0, outputTokens)) / 1_000_000.0 * pricing.outputPer1M
    }
}
