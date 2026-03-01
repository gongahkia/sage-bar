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
        return UsageSnapshot(
            accountId: account.id,
            timestamp: aggregated.timestamp,
            inputTokens: aggregated.inputTokens,
            outputTokens: aggregated.outputTokens,
            cacheCreationTokens: aggregated.cacheCreationTokens,
            cacheReadTokens: aggregated.cacheReadTokens,
            totalCostUSD: aggregated.totalCostUSD,
            modelBreakdown: aggregated.modelBreakdown,
            costConfidence: .estimated
        )
    }
}
