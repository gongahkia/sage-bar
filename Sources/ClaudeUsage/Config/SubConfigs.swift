import Foundation

struct TUIConfig: Codable {
    var layout: [String]
    var colorScheme: String
    var showLogo: Bool
    var separatorChar: String
    var labelWidth: Int
    static var `default`: TUIConfig {
        TUIConfig(
            layout: ["input_tokens","output_tokens","cache_tokens","cost_usd","last_updated","model_breakdown"],
            colorScheme: "default",
            showLogo: true,
            separatorChar: "─",
            labelWidth: 18
        )
    }
}

struct DisplayConfig: Codable {
    var menubarStyle: String // "icon" | "tokens" | "cost"
    var showBadge: Bool
    var compactMode: Bool
    var dualIcon: Bool
    static var `default`: DisplayConfig {
        DisplayConfig(menubarStyle: "icon", showBadge: true, compactMode: false, dualIcon: false)
    }
}

struct SparklineConfig: Codable {
    var enabled: Bool
    var windowHours: Int
    var style: String // "cost" | "tokens"
    var resolution: Int // data points
    static var `default`: SparklineConfig {
        SparklineConfig(enabled: true, windowHours: 168, style: "cost", resolution: 24)
    }
}

struct ForecastConfig: Codable {
    var enabled: Bool
    var showInPopover: Bool
    var showInTUI: Bool
    static var `default`: ForecastConfig {
        ForecastConfig(enabled: true, showInPopover: true, showInTUI: false)
    }
}

struct WebhookConfig: Codable {
    var enabled: Bool
    var url: String
    var events: [String] // "threshold" | "daily_digest" | "weekly_summary"
    var payloadTemplate: String?
    static var `default`: WebhookConfig {
        WebhookConfig(enabled: false, url: "", events: [], payloadTemplate: nil)
    }
}

struct AnalyticsConfig: Codable {
    var enabled: Bool
    var showMonthlyView: Bool
    var showHeatmap: Bool
    static var `default`: AnalyticsConfig {
        AnalyticsConfig(enabled: true, showMonthlyView: true, showHeatmap: false)
    }
}

struct ModelOptimizerConfig: Codable {
    var enabled: Bool
    var cheapThresholdTokens: Int
    var showInPopover: Bool
    static var `default`: ModelOptimizerConfig {
        ModelOptimizerConfig(enabled: true, cheapThresholdTokens: 1000, showInPopover: true)
    }
}

struct iCloudSyncConfig: Codable {
    var enabled: Bool
    var localOnly: Bool
    var containerIdentifier: String
    static var `default`: iCloudSyncConfig {
        iCloudSyncConfig(enabled: false, localOnly: true, containerIdentifier: "iCloud.dev.claudeusage")
    }
}

struct GlobalHotkeyConfig: Codable {
    var enabled: Bool
    var modifiers: [String]
    var key: String
    static var `default`: GlobalHotkeyConfig {
        GlobalHotkeyConfig(enabled: true, modifiers: ["option","command"], key: "c")
    }
}

struct ClaudeAIConfig: Codable {
    var sessionCookie: String? // sessionKey value from claude.ai DevTools
    static var `default`: ClaudeAIConfig { ClaudeAIConfig(sessionCookie: nil) }
}

struct AutomationRule: Codable, Identifiable {
    var id: UUID
    var name: String
    var triggerType: String // "cost_gt" | "tokens_gt"
    var threshold: Double
    var shellCommand: String
    var lastFiredAt: Date?
    var enabled: Bool
    var allowedEnvKeys: [String] // restrict env vars injected into process

    init(name: String, triggerType: String, threshold: Double, shellCommand: String) {
        self.id = UUID()
        self.name = name
        self.triggerType = triggerType
        self.threshold = threshold
        self.shellCommand = shellCommand
        self.lastFiredAt = nil
        self.enabled = true
        self.allowedEnvKeys = ["CLAUDE_COST", "CLAUDE_TOKENS", "CLAUDE_ACCOUNT"]
    }
}
