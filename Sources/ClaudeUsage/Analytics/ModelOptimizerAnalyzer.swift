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

    private enum PricingConfidenceLabel: String {
        case measured
        case profileEstimated
        case heuristicEstimated
    }

    private struct PricingEstimate {
        let currentCostUSD: Double
        let cheaperCostUSD: Double
        let confidence: PricingConfidenceLabel
    }

    private struct TaxonomyRule {
        let exactModelIDs: Set<String>
        let prefixMatchers: [String]
        let containsMatchers: [String]
    }

    private static let providerTaxonomy: [ProviderFamily: TaxonomyRule] = [
        .claude: TaxonomyRule(
            exactModelIDs: ["claude-code-local"],
            prefixMatchers: ["claude-opus", "claude-sonnet"],
            containsMatchers: ["opus", "sonnet"]
        ),
        .codex: TaxonomyRule(
            exactModelIDs: ["codex-local", "openai-org"],
            prefixMatchers: ["gpt-4", "o1", "o3", "o4"],
            containsMatchers: ["codex", "gpt-4.1", "gpt-5", "o1-", "o3-"]
        ),
        .gemini: TaxonomyRule(
            exactModelIDs: ["gemini-local"],
            prefixMatchers: ["gemini-2.5-pro", "gemini-1.5-pro", "gemini-pro"],
            containsMatchers: ["gemini-2.5-pro", "gemini-1.5-pro", "gemini-pro"]
        ),
    ]

    private static let heuristicCurrentPricingByFamily: [ProviderFamily: Pricing] = [
        .claude: Pricing(inputPer1M: 3.00, outputPer1M: 15.00),
        .codex: Pricing(inputPer1M: 2.00, outputPer1M: 8.00),
        .gemini: Pricing(inputPer1M: 1.25, outputPer1M: 5.00),
    ]

    private static let heuristicCheaperPricingByFamily: [ProviderFamily: Pricing] = [
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

        guard let recommendedModel = recommendedModelByFamily[family],
              let pricingEstimate = pricingEstimate(
                  family: family,
                  expensiveUsage: familyExpensive,
                  recommendedModel: recommendedModel,
                  measuredCurrentCost: measuredCurrentCost,
                  inputTokens: currentInputTotal,
                  outputTokens: currentOutputTotal
              ) else { return nil }
        let savings = pricingEstimate.currentCostUSD - pricingEstimate.cheaperCostUSD
        _ = pricingEstimate.confidence

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
        for (family, rule) in providerTaxonomy {
            if rule.exactModelIDs.contains(normalized) {
                return family
            }
            if rule.prefixMatchers.contains(where: { normalized.hasPrefix($0) }) {
                return family
            }
            if rule.containsMatchers.contains(where: { normalized.contains($0) }) {
                return family
            }
        }
        return nil
    }

    private static func pricingEstimate(
        family: ProviderFamily,
        expensiveUsage: [ModelUsage],
        recommendedModel: String,
        measuredCurrentCost: Double,
        inputTokens: Int,
        outputTokens: Int
    ) -> PricingEstimate? {
        guard let fallbackCurrent = heuristicCurrentPricingByFamily[family],
              let fallbackCheaper = heuristicCheaperPricingByFamily[family] else { return nil }

        let recommendedProfilePricing = pricingProfile(for: recommendedModel)
        let recommendedPricing = recommendedProfilePricing ?? fallbackCheaper
        let cheaperCost = estimatedCostUSD(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            pricing: recommendedPricing
        )

        if measuredCurrentCost > 0 {
            return PricingEstimate(
                currentCostUSD: measuredCurrentCost,
                cheaperCostUSD: cheaperCost,
                confidence: .measured
            )
        }

        var currentEstimatedCost = 0.0
        var usedHeuristicForCurrent = false
        for usage in expensiveUsage {
            let profilePricing = pricingProfile(for: usage.modelId)
            if profilePricing == nil {
                usedHeuristicForCurrent = true
            }
            let effectivePricing = profilePricing ?? fallbackCurrent
            currentEstimatedCost += estimatedCostUSD(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                pricing: effectivePricing
            )
        }
        let usedHeuristicForRecommended = recommendedProfilePricing == nil
        let confidence: PricingConfidenceLabel = (usedHeuristicForCurrent || usedHeuristicForRecommended)
            ? .heuristicEstimated
            : .profileEstimated
        return PricingEstimate(
            currentCostUSD: currentEstimatedCost,
            cheaperCostUSD: cheaperCost,
            confidence: confidence
        )
    }

    private static func pricingProfile(for modelId: String) -> Pricing? {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let matchedKey = AnthropicAPIClient.pricingConstants.keys
            .filter { normalized == $0 || normalized.hasPrefix($0) }
            .sorted { $0.count > $1.count }
            .first
        guard let matchedKey,
              let entry = AnthropicAPIClient.pricingConstants[matchedKey] else { return nil }
        return Pricing(inputPer1M: entry.inputPer1M, outputPer1M: entry.outputPer1M)
    }

    private static func estimatedCostUSD(inputTokens: Int, outputTokens: Int, pricing: Pricing) -> Double {
        Double(max(0, inputTokens)) / 1_000_000.0 * pricing.inputPer1M
        + Double(max(0, outputTokens)) / 1_000_000.0 * pricing.outputPer1M
    }
}
