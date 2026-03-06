import Foundation

struct Config: Codable {
    var schemaVersion: Int
    var accounts: [Account]
    var pollIntervalSeconds: Int
    var tui: TUIConfig
    var display: DisplayConfig
    var sparkline: SparklineConfig
    var forecast: ForecastConfig
    var burnRate: BurnRateConfig
    var webhook: WebhookConfig
    var analytics: AnalyticsConfig
    var modelOptimizer: ModelOptimizerConfig
    var iCloudSync: iCloudSyncConfig
    var hotkey: GlobalHotkeyConfig
    var automations: [AutomationRule]
    var claudeAI: ClaudeAIConfig
    var hotkeyConfig: HotkeyConfig
    var providerPolling: ProviderPollingConfig

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case accounts
        case pollIntervalSeconds
        case tui
        case display
        case sparkline
        case forecast
        case burnRate
        case webhook
        case analytics
        case modelOptimizer
        case iCloudSync
        case hotkey
        case automations
        case claudeAI
        case hotkeyConfig
        case providerPolling
    }

    static var `default`: Config {
        Config(
            schemaVersion: 3,
            accounts: [Account(name: "Local", type: .claudeCode, isActive: true)],
            pollIntervalSeconds: 300,
            tui: .default,
            display: .default,
            sparkline: .default,
            forecast: .default,
            burnRate: .default,
            webhook: .default,
            analytics: .default,
            modelOptimizer: .default,
            iCloudSync: .default,
            hotkey: .default,
            automations: [],
            claudeAI: .default,
            hotkeyConfig: .default,
            providerPolling: .default
        )
    }

    init(
        schemaVersion: Int,
        accounts: [Account],
        pollIntervalSeconds: Int,
        tui: TUIConfig,
        display: DisplayConfig,
        sparkline: SparklineConfig,
        forecast: ForecastConfig,
        burnRate: BurnRateConfig,
        webhook: WebhookConfig,
        analytics: AnalyticsConfig,
        modelOptimizer: ModelOptimizerConfig,
        iCloudSync: iCloudSyncConfig,
        hotkey: GlobalHotkeyConfig,
        automations: [AutomationRule],
        claudeAI: ClaudeAIConfig,
        hotkeyConfig: HotkeyConfig,
        providerPolling: ProviderPollingConfig = .default
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.pollIntervalSeconds = pollIntervalSeconds
        self.tui = tui
        self.display = display
        self.sparkline = sparkline
        self.forecast = forecast
        self.burnRate = burnRate
        self.webhook = webhook
        self.analytics = analytics
        self.modelOptimizer = modelOptimizer
        self.iCloudSync = iCloudSync
        self.hotkey = hotkey
        self.automations = automations
        self.claudeAI = claudeAI
        self.hotkeyConfig = hotkeyConfig
        self.providerPolling = providerPolling
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accounts = try c.decode([Account].self, forKey: .accounts)
        pollIntervalSeconds = try c.decode(Int.self, forKey: .pollIntervalSeconds)
        tui = try c.decode(TUIConfig.self, forKey: .tui)
        display = try c.decode(DisplayConfig.self, forKey: .display)
        sparkline = try c.decode(SparklineConfig.self, forKey: .sparkline)
        forecast = try c.decode(ForecastConfig.self, forKey: .forecast)
        burnRate = try c.decodeIfPresent(BurnRateConfig.self, forKey: .burnRate) ?? .default
        webhook = try c.decode(WebhookConfig.self, forKey: .webhook)
        analytics = try c.decode(AnalyticsConfig.self, forKey: .analytics)
        modelOptimizer = try c.decode(ModelOptimizerConfig.self, forKey: .modelOptimizer)
        iCloudSync = try c.decode(iCloudSyncConfig.self, forKey: .iCloudSync)
        hotkey = try c.decode(GlobalHotkeyConfig.self, forKey: .hotkey)
        automations = try c.decode([AutomationRule].self, forKey: .automations)
        claudeAI = try c.decode(ClaudeAIConfig.self, forKey: .claudeAI)
        hotkeyConfig = try c.decode(HotkeyConfig.self, forKey: .hotkeyConfig)
        providerPolling = try c.decodeIfPresent(ProviderPollingConfig.self, forKey: .providerPolling) ?? .default
    }
}
