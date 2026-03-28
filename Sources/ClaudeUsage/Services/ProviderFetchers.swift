import Foundation

enum ProviderFetchers {
    static func localSnapshot(for account: Account) -> UsageSnapshot? {
        let aggregated: UsageSnapshot
        switch account.type {
        case .claudeCode:
            aggregated = ClaudeCodeLogParser.shared.aggregateToday()
        case .codex:
            aggregated = CodexLogParser.shared.aggregateToday()
        case .gemini:
            aggregated = GeminiLogParser.shared.aggregateToday()
        default:
            return nil
        }
        let priced = applyPricing(to: aggregated)
        return UsageSnapshot(
            accountId: account.id,
            timestamp: priced.timestamp,
            inputTokens: priced.inputTokens,
            outputTokens: priced.outputTokens,
            cacheCreationTokens: priced.cacheCreationTokens,
            cacheReadTokens: priced.cacheReadTokens,
            totalCostUSD: priced.totalCostUSD,
            modelBreakdown: priced.modelBreakdown,
            costConfidence: .estimated
        )
    }

    private static func applyPricing(to snapshot: UsageSnapshot) -> UsageSnapshot {
        let prices = AnthropicAPIClient.pricingConstants
        var totalCost = 0.0
        let pricedBreakdown = snapshot.modelBreakdown.map { model -> ModelUsage in
            let price = prices.first { model.modelId.hasPrefix($0.key) }?.value
            guard let price else { return model }
            let cost = Double(model.inputTokens) / 1_000_000 * price.inputPer1M
                + Double(model.outputTokens) / 1_000_000 * price.outputPer1M
                + Double(model.cacheTokens) / 1_000_000 * price.inputPer1M * 0.1 // cache read discount
            totalCost += cost
            return ModelUsage(
                modelId: model.modelId,
                inputTokens: model.inputTokens,
                outputTokens: model.outputTokens,
                cacheTokens: model.cacheTokens,
                costUSD: cost
            )
        }
        return UsageSnapshot(
            accountId: snapshot.accountId,
            timestamp: snapshot.timestamp,
            inputTokens: snapshot.inputTokens,
            outputTokens: snapshot.outputTokens,
            cacheCreationTokens: snapshot.cacheCreationTokens,
            cacheReadTokens: snapshot.cacheReadTokens,
            totalCostUSD: totalCost,
            modelBreakdown: pricedBreakdown,
            costConfidence: .estimated
        )
    }
}
