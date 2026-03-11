import Foundation

enum ClaudeAISessionHealth: String, Codable, Equatable {
    case healthy
    case temporaryFailure
    case reauthRequired
}

struct ClaudeAIStatus: Codable, Equatable {
    var accountId: UUID
    var messagesRemaining: Int
    var messagesUsed: Int
    var resetAt: Date?
    var lastUpdated: Date
    var lastSuccessfulSyncAt: Date?
    var lastErrorMessage: String?
    var sessionHealth: ClaudeAISessionHealth

    private enum CodingKeys: String, CodingKey {
        case accountId
        case messagesRemaining
        case messagesUsed
        case resetAt
        case lastUpdated
        case lastSuccessfulSyncAt
        case lastErrorMessage
        case sessionHealth
    }

    init(
        accountId: UUID,
        messagesRemaining: Int,
        messagesUsed: Int,
        resetAt: Date?,
        lastUpdated: Date,
        lastSuccessfulSyncAt: Date? = nil,
        lastErrorMessage: String? = nil,
        sessionHealth: ClaudeAISessionHealth = .healthy
    ) {
        self.accountId = accountId
        self.messagesRemaining = messagesRemaining
        self.messagesUsed = messagesUsed
        self.resetAt = resetAt
        self.lastUpdated = lastUpdated
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastErrorMessage = lastErrorMessage
        self.sessionHealth = sessionHealth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        messagesRemaining = try c.decode(Int.self, forKey: .messagesRemaining)
        messagesUsed = try c.decode(Int.self, forKey: .messagesUsed)
        resetAt = try c.decodeIfPresent(Date.self, forKey: .resetAt)
        lastUpdated = try c.decode(Date.self, forKey: .lastUpdated)
        lastSuccessfulSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulSyncAt)
        lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        sessionHealth = try c.decodeIfPresent(ClaudeAISessionHealth.self, forKey: .sessionHealth) ?? .healthy
    }
}

actor ClaudeAIStatusStore {
    static let shared = ClaudeAIStatusStore()

    private let fileURL: URL
    private var cachedStatuses: [String: ClaudeAIStatus]?

    init(fileURL: URL = AppConstants.sharedContainerURL.appendingPathComponent("claude_ai_status.json")) {
        self.fileURL = fileURL
    }

    func status(for accountId: UUID) -> ClaudeAIStatus? {
        loadAll()[accountId.uuidString]
    }

    func save(_ status: ClaudeAIStatus) {
        var statuses = loadAll()
        statuses[status.accountId.uuidString] = status
        persist(statuses)
    }

    func remove(accountId: UUID) {
        var statuses = loadAll()
        statuses.removeValue(forKey: accountId.uuidString)
        persist(statuses)
    }

    func resetForTests() {
        cachedStatuses = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadAll() -> [String: ClaudeAIStatus] {
        if let cachedStatuses {
            return cachedStatuses
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedStatuses = [:]
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([String: ClaudeAIStatus].self, from: data)) ?? [:]
        cachedStatuses = decoded
        return decoded
    }

    private func persist(_ statuses: [String: ClaudeAIStatus]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(statuses)
            try AtomicFileWriter.write(data, to: fileURL)
            cachedStatuses = statuses
        } catch {
            ErrorLogger.shared.log("Failed to persist Claude AI status: \(error.localizedDescription)")
        }
    }
}
