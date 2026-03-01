import Foundation

struct TUIConfig: Codable, Equatable {
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

struct DisplayConfig: Codable, Equatable {
    var menubarStyle: String // "icon" | "tokens" | "cost"
    var showBadge: Bool
    var compactMode: Bool
    var dualIcon: Bool
    var showExperimentalProviders: Bool

    enum CodingKeys: String, CodingKey {
        case menubarStyle
        case showBadge
        case compactMode
        case dualIcon
        case showExperimentalProviders
    }

    init(
        menubarStyle: String,
        showBadge: Bool,
        compactMode: Bool,
        dualIcon: Bool,
        showExperimentalProviders: Bool
    ) {
        self.menubarStyle = menubarStyle
        self.showBadge = showBadge
        self.compactMode = compactMode
        self.dualIcon = dualIcon
        self.showExperimentalProviders = showExperimentalProviders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menubarStyle = try c.decode(String.self, forKey: .menubarStyle)
        showBadge = try c.decode(Bool.self, forKey: .showBadge)
        compactMode = try c.decode(Bool.self, forKey: .compactMode)
        dualIcon = try c.decode(Bool.self, forKey: .dualIcon)
        showExperimentalProviders = try c.decodeIfPresent(Bool.self, forKey: .showExperimentalProviders) ?? false
    }

    static var `default`: DisplayConfig {
        DisplayConfig(
            menubarStyle: "icon",
            showBadge: true,
            compactMode: false,
            dualIcon: false,
            showExperimentalProviders: false
        )
    }
}

struct SparklineConfig: Codable, Equatable {
    var enabled: Bool
    var windowHours: Int
    var style: String // "cost" | "tokens"
    var resolution: Int // data points
    static var `default`: SparklineConfig {
        SparklineConfig(enabled: true, windowHours: 168, style: "cost", resolution: 24)
    }
}

struct ForecastConfig: Codable, Equatable {
    var enabled: Bool
    var showInPopover: Bool
    var showInTUI: Bool
    static var `default`: ForecastConfig {
        ForecastConfig(enabled: true, showInPopover: true, showInTUI: false)
    }
}

struct BurnRateConfig: Codable, Equatable {
    var enabled: Bool
    var defaultUSDPerHourThreshold: Double
    var perAccountUSDPerHourThreshold: [String: Double]
    var alertCooldownSeconds: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case defaultUSDPerHourThreshold
        case perAccountUSDPerHourThreshold
        case alertCooldownSeconds
    }

    init(
        enabled: Bool,
        defaultUSDPerHourThreshold: Double,
        perAccountUSDPerHourThreshold: [String: Double],
        alertCooldownSeconds: Int
    ) {
        self.enabled = enabled
        self.defaultUSDPerHourThreshold = defaultUSDPerHourThreshold
        self.perAccountUSDPerHourThreshold = perAccountUSDPerHourThreshold
        self.alertCooldownSeconds = alertCooldownSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        defaultUSDPerHourThreshold = try c.decodeIfPresent(Double.self, forKey: .defaultUSDPerHourThreshold) ?? 10.0
        perAccountUSDPerHourThreshold = try c.decodeIfPresent([String: Double].self, forKey: .perAccountUSDPerHourThreshold) ?? [:]
        alertCooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .alertCooldownSeconds) ?? 3600
    }

    static var `default`: BurnRateConfig {
        BurnRateConfig(
            enabled: false,
            defaultUSDPerHourThreshold: 10.0,
            perAccountUSDPerHourThreshold: [:],
            alertCooldownSeconds: 3600
        )
    }
}

struct WebhookConfig: Codable, Equatable {
    var enabled: Bool
    var url: String
    var events: [String] // "threshold" | "burn_rate" | "daily_digest" | "weekly_summary"
    var payloadTemplate: String?
    var allowedHosts: [String]

    enum CodingKeys: String, CodingKey {
        case enabled
        case url
        case events
        case payloadTemplate
        case allowedHosts
    }

    init(enabled: Bool, url: String, events: [String], payloadTemplate: String?, allowedHosts: [String] = ["hooks.slack.com", "discord.com", "api.github.com"]) {
        self.enabled = enabled
        self.url = url
        self.events = events
        self.payloadTemplate = payloadTemplate
        self.allowedHosts = allowedHosts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        url = try c.decode(String.self, forKey: .url)
        events = try c.decode([String].self, forKey: .events)
        payloadTemplate = try c.decodeIfPresent(String.self, forKey: .payloadTemplate)
        allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? Self.default.allowedHosts
    }

    static var `default`: WebhookConfig {
        WebhookConfig(
            enabled: false,
            url: "",
            events: [],
            payloadTemplate: nil,
            allowedHosts: ["hooks.slack.com", "discord.com", "api.github.com"]
        )
    }
}

struct AnalyticsConfig: Codable, Equatable {
    var enabled: Bool
    var showMonthlyView: Bool
    var showHeatmap: Bool
    static var `default`: AnalyticsConfig {
        AnalyticsConfig(enabled: true, showMonthlyView: true, showHeatmap: false)
    }
}

struct ModelOptimizerConfig: Codable, Equatable {
    var enabled: Bool
    var cheapThresholdTokens: Int
    var showInPopover: Bool
    static var `default`: ModelOptimizerConfig {
        ModelOptimizerConfig(enabled: true, cheapThresholdTokens: 1000, showInPopover: true)
    }
}

struct iCloudSyncConfig: Codable, Equatable {
    var enabled: Bool
    var localOnly: Bool
    var containerIdentifier: String
    static var `default`: iCloudSyncConfig {
        iCloudSyncConfig(enabled: false, localOnly: true, containerIdentifier: "iCloud.dev.claudeusage")
    }
}

struct GlobalHotkeyConfig: Codable, Equatable {
    var enabled: Bool
    var modifiers: [String]
    var key: String
    static var `default`: GlobalHotkeyConfig {
        GlobalHotkeyConfig(enabled: true, modifiers: ["option","command"], key: "c")
    }
}

struct HotkeyConfig: Codable, Equatable {
    var primaryKeyCode: Int         // virtual key code (e.g., 32 for U)
    var primaryModifiers: [String]  // ["command","shift"]
    var chordEnabled: Bool
    var chordSecondaryKeyCode: Int  // secondary key code when chordEnabled
    static var `default`: HotkeyConfig {
        HotkeyConfig(primaryKeyCode: 32, primaryModifiers: ["command","shift"],
                     chordEnabled: false, chordSecondaryKeyCode: 0)
    }
}

struct ClaudeAIConfig: Codable, Equatable {
    private enum LegacyCodingKeys: String, CodingKey {
        case sessionCookie
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let cookie = try c.decodeIfPresent(String.self, forKey: .sessionCookie),
           !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ErrorLogger.shared.log(
                "Ignoring deprecated claudeAI.sessionCookie in config; use keychain-backed session tokens instead",
                level: "WARN"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        // deprecated and intentionally omitted to avoid persisting sensitive cookie fields
        _ = encoder.container(keyedBy: LegacyCodingKeys.self)
    }

    static var `default`: ClaudeAIConfig { ClaudeAIConfig() }
}

struct AutomationRule: Codable, Identifiable, Equatable {
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
