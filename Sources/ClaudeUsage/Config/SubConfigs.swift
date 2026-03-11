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

struct ProviderPollingConfig: Codable, Equatable {
    var claudeCode: Int
    var codex: Int
    var gemini: Int
    var anthropicAPI: Int
    var openAIOrg: Int
    var windsurfEnterprise: Int
    var githubCopilot: Int
    var claudeAI: Int
    static var `default`: ProviderPollingConfig {
        ProviderPollingConfig(
            claudeCode: 300, codex: 300, gemini: 300,
            anthropicAPI: 300, openAIOrg: 900,
            windsurfEnterprise: 600, githubCopilot: 3600, claudeAI: 300
        )
    }
    func interval(for type: AccountType) -> Int {
        switch type {
        case .claudeCode: return claudeCode
        case .codex: return codex
        case .gemini: return gemini
        case .anthropicAPI: return anthropicAPI
        case .openAIOrg: return openAIOrg
        case .windsurfEnterprise: return windsurfEnterprise
        case .githubCopilot: return githubCopilot
        case .claudeAI: return claudeAI
        }
    }
    mutating func setInterval(_ seconds: Int, for type: AccountType) {
        switch type {
        case .claudeCode: claudeCode = seconds
        case .codex: codex = seconds
        case .gemini: gemini = seconds
        case .anthropicAPI: anthropicAPI = seconds
        case .openAIOrg: openAIOrg = seconds
        case .windsurfEnterprise: windsurfEnterprise = seconds
        case .githubCopilot: githubCopilot = seconds
        case .claudeAI: claudeAI = seconds
        }
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
    var notifyOnLowMessages: Bool
    var lowMessagesThreshold: Int

    private enum CodingKeys: String, CodingKey {
        case notifyOnLowMessages
        case lowMessagesThreshold
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case sessionCookie
    }

    init(
        notifyOnLowMessages: Bool = true,
        lowMessagesThreshold: Int = 10
    ) {
        self.notifyOnLowMessages = notifyOnLowMessages
        self.lowMessagesThreshold = Self.sanitizedThreshold(lowMessagesThreshold)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifyOnLowMessages = try c.decodeIfPresent(Bool.self, forKey: .notifyOnLowMessages) ?? true
        lowMessagesThreshold = Self.sanitizedThreshold(try c.decodeIfPresent(Int.self, forKey: .lowMessagesThreshold) ?? 10)

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let cookie = try legacy.decodeIfPresent(String.self, forKey: .sessionCookie),
           !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ErrorLogger.shared.log(
                "Ignoring deprecated claudeAI.sessionCookie in config; use keychain-backed session tokens instead",
                level: "WARN"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notifyOnLowMessages, forKey: .notifyOnLowMessages)
        try container.encode(lowMessagesThreshold, forKey: .lowMessagesThreshold)
    }

    static var `default`: ClaudeAIConfig { ClaudeAIConfig() }

    private static func sanitizedThreshold(_ value: Int) -> Int {
        value > 0 ? value : 10
    }
}

struct AutomationRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var triggerType: String // "cost_gt" | "tokens_gt"
    var threshold: Double
    var actionKind: String
    var actionPayload: String?
    var accountIDs: [UUID]
    var groupLabels: [String]
    var shellCommand: String
    var lastFiredAt: Date?
    var enabled: Bool
    var allowedEnvKeys: [String] // restrict env vars injected into process

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case triggerType
        case threshold
        case actionKind
        case actionPayload
        case accountIDs
        case groupLabels
        case shellCommand
        case lastFiredAt
        case enabled
        case allowedEnvKeys
    }

    init(
        name: String,
        triggerType: String,
        threshold: Double,
        shellCommand: String,
        actionKind: String = "shell",
        actionPayload: String? = nil,
        accountIDs: [UUID] = [],
        groupLabels: [String] = []
    ) {
        self.id = UUID()
        self.name = name
        self.triggerType = triggerType
        self.threshold = threshold
        self.actionKind = actionKind
        self.actionPayload = actionPayload ?? (actionKind == "shell" ? shellCommand : nil)
        self.accountIDs = accountIDs
        self.groupLabels = Self.normalizedGroupLabels(groupLabels)
        self.shellCommand = shellCommand
        self.lastFiredAt = nil
        self.enabled = true
        self.allowedEnvKeys = ["CLAUDE_COST", "CLAUDE_TOKENS", "CLAUDE_ACCOUNT"]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        triggerType = try c.decode(String.self, forKey: .triggerType)
        threshold = try c.decode(Double.self, forKey: .threshold)
        actionKind = try c.decodeIfPresent(String.self, forKey: .actionKind) ?? "shell"
        actionPayload = try c.decodeIfPresent(String.self, forKey: .actionPayload)
        accountIDs = try c.decodeIfPresent([UUID].self, forKey: .accountIDs) ?? []
        groupLabels = Self.normalizedGroupLabels(
            try c.decodeIfPresent([String].self, forKey: .groupLabels) ?? []
        )
        shellCommand = try c.decodeIfPresent(String.self, forKey: .shellCommand) ?? ""
        lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowedEnvKeys = try c.decodeIfPresent([String].self, forKey: .allowedEnvKeys)
            ?? ["CLAUDE_COST", "CLAUDE_TOKENS", "CLAUDE_ACCOUNT"]
        if actionKind == "shell", actionPayload == nil, !shellCommand.isEmpty {
            actionPayload = shellCommand
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(triggerType, forKey: .triggerType)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(actionKind, forKey: .actionKind)
        try c.encodeIfPresent(actionPayload, forKey: .actionPayload)
        try c.encode(accountIDs, forKey: .accountIDs)
        try c.encode(groupLabels, forKey: .groupLabels)
        try c.encode(shellCommand, forKey: .shellCommand)
        try c.encodeIfPresent(lastFiredAt, forKey: .lastFiredAt)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(allowedEnvKeys, forKey: .allowedEnvKeys)
    }

    private static func normalizedGroupLabels(_ labels: [String]) -> [String] {
        Array(
            Set(
                labels
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }
}
