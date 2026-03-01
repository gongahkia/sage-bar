import XCTest
@testable import ClaudeUsage

final class ModelOptimizerAnalyzerTests: XCTestCase {
    private let accountId = UUID()
    private let enabledConfig = ModelOptimizerConfig(enabled: true, cheapThresholdTokens: 1000, showInPopover: true)
    private let disabledConfig = ModelOptimizerConfig(enabled: false, cheapThresholdTokens: 1000, showInPopover: false)

    private func usage(model: String, input: Int, output: Int, cost: Double) -> ModelUsage {
        ModelUsage(modelId: model, inputTokens: input, outputTokens: output, costUSD: cost)
    }

    func testDisabledConfigReturnsNil() {
        let mu = [usage(model: "claude-sonnet-4-6", input: 1_000_000, output: 500, cost: 10.0)]
        XCTAssertNil(ModelOptimizerAnalyzer.analyze(breakdown: mu, accountId: accountId, config: disabledConfig))
    }

    func testBelowThresholdTriggerHint() {
        // output < cheapThresholdTokens (1000) → should trigger
        let mu = [usage(model: "claude-opus-4-6", input: 1_000_000, output: 500, cost: 15.0)]
        let hint = ModelOptimizerAnalyzer.analyze(breakdown: mu, accountId: accountId, config: enabledConfig)
        XCTAssertNotNil(hint)
        XCTAssertEqual(hint?.recommendedModel, "claude-3-haiku")
        XCTAssertGreaterThan(hint?.estimatedSavingsUSD ?? 0, 0)
    }

    func testAboveThresholdReturnsNil() {
        // output >= cheapThresholdTokens → no hint
        let mu = [usage(model: "claude-sonnet-4-6", input: 1_000_000, output: 2000, cost: 3.0)]
        XCTAssertNil(ModelOptimizerAnalyzer.analyze(breakdown: mu, accountId: accountId, config: enabledConfig))
    }

    func testNoExpensiveModelsReturnsNil() {
        let mu = [usage(model: "claude-3-haiku", input: 1_000_000, output: 100, cost: 0.25)]
        XCTAssertNil(ModelOptimizerAnalyzer.analyze(breakdown: mu, accountId: accountId, config: enabledConfig))
    }

    func testEmptyBreakdownReturnsNil() {
        XCTAssertNil(ModelOptimizerAnalyzer.analyze(breakdown: [], accountId: accountId, config: enabledConfig))
    }

    func testCodexProviderRuleSuggestsCheaperModel() {
        let mu = [usage(model: "codex-local", input: 1_000_000, output: 500, cost: 0)]
        let hint = ModelOptimizerAnalyzer.analyze(breakdown: mu, accountId: accountId, config: enabledConfig)
        XCTAssertNotNil(hint)
        XCTAssertEqual(hint?.recommendedModel, "gpt-4o-mini")
        XCTAssertGreaterThan(hint?.estimatedSavingsUSD ?? 0, 0)
    }

    func testGeminiProviderRuleSuggestsCheaperModel() {
        let mu = [usage(model: "gemini-local", input: 1_000_000, output: 500, cost: 0)]
        let hint = ModelOptimizerAnalyzer.analyze(breakdown: mu, accountId: accountId, config: enabledConfig)
        XCTAssertNotNil(hint)
        XCTAssertEqual(hint?.recommendedModel, "gemini-2.0-flash")
        XCTAssertGreaterThan(hint?.estimatedSavingsUSD ?? 0, 0)
    }

    func testOpenAIModelIDUsesCodexTaxonomyRule() {
        let mu = [usage(model: "gpt-4.1", input: 1_000_000, output: 500, cost: 0)]
        let hint = ModelOptimizerAnalyzer.analyze(breakdown: mu, accountId: accountId, config: enabledConfig)
        XCTAssertNotNil(hint)
        XCTAssertEqual(hint?.recommendedModel, "gpt-4o-mini")
    }

    func testGeminiProModelIDUsesGeminiTaxonomyRule() {
        let mu = [usage(model: "gemini-2.5-pro-preview", input: 1_000_000, output: 500, cost: 0)]
        let hint = ModelOptimizerAnalyzer.analyze(breakdown: mu, accountId: accountId, config: enabledConfig)
        XCTAssertNotNil(hint)
        XCTAssertEqual(hint?.recommendedModel, "gemini-2.0-flash")
    }
}
