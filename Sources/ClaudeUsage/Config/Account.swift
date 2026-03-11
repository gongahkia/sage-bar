import Foundation

enum AccountType: String, Codable, CaseIterable {
    case claudeCode = "claudeCode"     // no credentials needed
    case codex = "codex"               // local Codex session logs
    case gemini = "gemini"             // local Gemini CLI session logs
    case anthropicAPI = "anthropicAPI" // requires keychain key
    case openAIOrg = "openAIOrg"       // OpenAI organization usage/cost APIs
    case windsurfEnterprise = "windsurfEnterprise" // Windsurf enterprise analytics APIs
    case githubCopilot = "githubCopilot" // GitHub Copilot organization usage metrics
    case claudeAI = "claudeAI"        // session-based web account
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .anthropicAPI: return "Anthropic API"
        case .openAIOrg: return "OpenAI Org"
        case .windsurfEnterprise: return "Windsurf Enterprise"
        case .githubCopilot: return "GitHub Copilot"
        case .claudeAI: return "Claude AI"
        }
    }
}

enum ProviderCredentialMode: Equatable {
    case none
    case anthropicAPIKey
    case openAIAdminKey
    case windsurfServiceKey
    case githubTokenAndOrg
    case claudeAISessionToken
}

enum ProviderStrategy: String, Codable {
    case core
    case experimental
}

struct ProviderCapabilities {
    let credentialMode: ProviderCredentialMode
    let supportsConnectionTest: Bool
}

extension AccountType {
    var providerStrategy: ProviderStrategy {
        switch self {
        case .claudeCode, .codex, .gemini:
            return .core
        case .anthropicAPI, .openAIOrg, .windsurfEnterprise, .githubCopilot, .claudeAI:
            return .experimental
        }
    }

    var isCoreProvider: Bool { providerStrategy == .core }

    var supportsWorkstreamAttribution: Bool {
        switch self {
        case .claudeCode, .codex, .gemini:
            return true
        default:
            return false
        }
    }

    var capabilities: ProviderCapabilities {
        switch self {
        case .claudeCode, .codex, .gemini:
            return ProviderCapabilities(credentialMode: .none, supportsConnectionTest: true)
        case .anthropicAPI:
            return ProviderCapabilities(credentialMode: .anthropicAPIKey, supportsConnectionTest: true)
        case .openAIOrg:
            return ProviderCapabilities(credentialMode: .openAIAdminKey, supportsConnectionTest: true)
        case .windsurfEnterprise:
            return ProviderCapabilities(credentialMode: .windsurfServiceKey, supportsConnectionTest: true)
        case .githubCopilot:
            return ProviderCapabilities(credentialMode: .githubTokenAndOrg, supportsConnectionTest: true)
        case .claudeAI:
            return ProviderCapabilities(credentialMode: .claudeAISessionToken, supportsConnectionTest: true)
        }
    }
}

struct WorkstreamRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var pathPattern: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case pathPattern
    }

    init(name: String, pathPattern: String) {
        self.id = UUID()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pathPattern = pathPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(id: UUID, name: String, pathPattern: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pathPattern = pathPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        pathPattern = try c.decode(String.self, forKey: .pathPattern).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Account: Codable, Identifiable {
    var id: UUID
    var name: String
    var type: AccountType
    var isActive: Bool
    var groupLabel: String?
    var isPinned: Bool
    var workstreamRules: [WorkstreamRule]
    var order: Int
    var createdAt: Date
    var costLimitUSD: Double? // per-account daily limit for notifications

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case isActive
        case groupLabel
        case isPinned
        case workstreamRules
        case order
        case createdAt
        case costLimitUSD
    }

    init(
        name: String,
        type: AccountType,
        isActive: Bool = true,
        groupLabel: String? = nil,
        isPinned: Bool = false,
        workstreamRules: [WorkstreamRule] = [],
        order: Int = 0,
        costLimitUSD: Double? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.isActive = isActive
        let trimmedGroupLabel = groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.groupLabel = trimmedGroupLabel.isEmpty ? nil : trimmedGroupLabel
        self.isPinned = isPinned
        self.workstreamRules = Account.normalizedWorkstreamRules(workstreamRules)
        self.order = order
        self.createdAt = Date()
        if let limit = costLimitUSD, limit <= 0 { // task 87: warn on invalid costLimitUSD
            ErrorLogger.shared.log("Account '\(name)' costLimitUSD \(limit) must be > 0; ignoring", level: "WARN")
            self.costLimitUSD = nil
        } else {
            self.costLimitUSD = costLimitUSD
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(AccountType.self, forKey: .type)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        let decodedGroupLabel = try c.decodeIfPresent(String.self, forKey: .groupLabel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        groupLabel = decodedGroupLabel.isEmpty ? nil : decodedGroupLabel
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        workstreamRules = Account.normalizedWorkstreamRules(
            try c.decodeIfPresent([WorkstreamRule].self, forKey: .workstreamRules) ?? []
        )
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        costLimitUSD = try c.decodeIfPresent(Double.self, forKey: .costLimitUSD)
    }
}

extension Account {
    static func displayOrder(_ lhs: Account, _ rhs: Account) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }
        if lhs.order == rhs.order {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.order < rhs.order
    }

    static func sortedForDisplay(_ accounts: [Account]) -> [Account] {
        accounts.sorted(by: displayOrder)
    }

    static func activeAccounts(in config: Config) -> [Account] {
        sortedForDisplay(config.accounts.filter(\.isActive))
    }

    static func preferredAccount(
        from accounts: [Account],
        userDefaults: UserDefaults = .standard
    ) -> Account? {
        guard !accounts.isEmpty else { return nil }
        if let savedID = userDefaults.string(forKey: AppConstants.selectedAccountDefaultsKey),
           let match = accounts.first(where: { $0.id.uuidString == savedID }) {
            return match
        }
        return accounts.first
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedGroupLabel: String? {
        let trimmed = groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasWorkstreamRules: Bool {
        !workstreamRules.isEmpty
    }

    func resolvedDisplayName(among accounts: [Account]) -> String {
        let normalized = trimmedName.lowercased()
        guard !normalized.isEmpty else {
            return "\(type.rawValue)-\(id.uuidString.prefix(6))"
        }
        let duplicateCount = accounts.filter {
            $0.trimmedName.lowercased() == normalized
        }.count
        if duplicateCount > 1 {
            return "\(type.rawValue)-\(id.uuidString.prefix(6))"
        }
        return trimmedName
    }

    func displayLabel(among accounts: [Account], includeGroupLabel: Bool = true) -> String {
        let base = resolvedDisplayName(among: accounts)
        guard includeGroupLabel, let group = trimmedGroupLabel else {
            return base
        }
        return "\(base) • \(group)"
    }

    func resolvedWorkstreamLabel(for sourcePath: String) -> String {
        let normalizedPath = sourcePath.lowercased()
        if let match = workstreamRules.first(where: { rule in
            let pattern = rule.pathPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !pattern.isEmpty && normalizedPath.contains(pattern)
        }) {
            return match.name
        }
        return Self.inferredWorkstreamLabel(for: type, sourcePath: sourcePath)
    }

    private static func inferredWorkstreamLabel(for type: AccountType, sourcePath: String) -> String {
        let url = URL(fileURLWithPath: sourcePath)
        let components = url.standardizedFileURL.pathComponents
        let rawLabel: String
        switch type {
        case .claudeCode:
            if let projectsIndex = components.firstIndex(of: "projects"),
               components.indices.contains(projectsIndex + 1) {
                rawLabel = components[projectsIndex + 1]
            } else {
                rawLabel = url.deletingLastPathComponent().lastPathComponent
            }
        case .codex:
            if let sessionsIndex = components.firstIndex(of: "sessions"),
               components.indices.contains(sessionsIndex + 1) {
                rawLabel = components[sessionsIndex + 1]
            } else {
                rawLabel = url.deletingLastPathComponent().lastPathComponent
            }
        case .gemini:
            if let chatsIndex = components.firstIndex(of: "chats"), chatsIndex > 0 {
                rawLabel = components[chatsIndex - 1]
            } else {
                rawLabel = url.deletingLastPathComponent().lastPathComponent
            }
        default:
            rawLabel = url.deletingLastPathComponent().lastPathComponent
        }
        let decoded = rawLabel.removingPercentEncoding ?? rawLabel
        let cleaned = decoded
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Unassigned" : cleaned
    }

    private static func normalizedWorkstreamRules(_ rules: [WorkstreamRule]) -> [WorkstreamRule] {
        rules.map { rule in
            let trimmedName = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPattern = rule.pathPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            return WorkstreamRule(id: rule.id, name: trimmedName, pathPattern: trimmedPattern)
        }
    }
}
