import Foundation

struct Config: Codable {
    var accounts: [Account]
    var pollIntervalSeconds: Int
    var tui: TUIConfig
    var display: DisplayConfig
    var sparkline: SparklineConfig
    var forecast: ForecastConfig
    var webhook: WebhookConfig
    var analytics: AnalyticsConfig
    var modelOptimizer: ModelOptimizerConfig
    var iCloudSync: iCloudSyncConfig
    var hotkey: GlobalHotkeyConfig
    var automations: [AutomationRule]
    var claudeAI: ClaudeAIConfig
    var hotkeyConfig: HotkeyConfig

    static var `default`: Config {
        Config(
            accounts: [Account(name: "Local", type: .claudeCode, isActive: true)],
            pollIntervalSeconds: 300,
            tui: .default,
            display: .default,
            sparkline: .default,
            forecast: .default,
            webhook: .default,
            analytics: .default,
            modelOptimizer: .default,
            iCloudSync: .default,
            hotkey: .default,
            automations: [],
            claudeAI: .default,
            hotkeyConfig: .default
        )
    }
}
