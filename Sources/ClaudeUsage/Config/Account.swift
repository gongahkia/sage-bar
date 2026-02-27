import Foundation

enum AccountType: String, Codable, CaseIterable {
    case claudeCode = "claudeCode"     // no credentials needed
    case anthropicAPI = "anthropicAPI" // requires keychain key
    case claudeAI = "claudeAI"        // unsupported/deferred
    var isSupported: Bool { self != .claudeAI }
}

struct Account: Codable, Identifiable {
    var id: UUID
    var name: String
    var type: AccountType
    var isActive: Bool
    var createdAt: Date
    var costLimitUSD: Double? // per-account daily limit for notifications

    init(name: String, type: AccountType, isActive: Bool = true) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.isActive = isActive
        self.createdAt = Date()
        self.costLimitUSD = nil
    }
}
