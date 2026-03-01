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
}

struct Account: Codable, Identifiable {
    var id: UUID
    var name: String
    var type: AccountType
    var isActive: Bool
    var order: Int
    var createdAt: Date
    var costLimitUSD: Double? // per-account daily limit for notifications

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case isActive
        case order
        case createdAt
        case costLimitUSD
    }

    init(name: String, type: AccountType, isActive: Bool = true, order: Int = 0, costLimitUSD: Double? = nil) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.isActive = isActive
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
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        costLimitUSD = try c.decodeIfPresent(Double.self, forKey: .costLimitUSD)
    }
}
