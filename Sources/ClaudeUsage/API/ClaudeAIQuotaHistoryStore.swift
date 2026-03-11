import Foundation

struct ClaudeAIQuotaHistoryEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var accountId: UUID
    var timestamp: Date
    var messagesRemaining: Int
    var messagesUsed: Int
    var resetAt: Date?
    var sessionHealth: ClaudeAISessionHealth

    init(
        accountId: UUID,
        timestamp: Date,
        messagesRemaining: Int,
        messagesUsed: Int,
        resetAt: Date?,
        sessionHealth: ClaudeAISessionHealth
    ) {
        self.id = UUID()
        self.accountId = accountId
        self.timestamp = timestamp
        self.messagesRemaining = messagesRemaining
        self.messagesUsed = messagesUsed
        self.resetAt = resetAt
        self.sessionHealth = sessionHealth
    }
}

actor ClaudeAIQuotaHistoryStore {
    static let shared = ClaudeAIQuotaHistoryStore()

    private let fileURL: URL
    private var cachedEntries: [ClaudeAIQuotaHistoryEntry]?
    private let maxEntries = 300

    init(fileURL: URL = AppConstants.sharedContainerURL.appendingPathComponent("claude_ai_quota_history.json")) {
        self.fileURL = fileURL
    }

    func history(for accountId: UUID, limit: Int = 12) -> [ClaudeAIQuotaHistoryEntry] {
        Array(loadAll().filter { $0.accountId == accountId }.prefix(max(0, limit)))
    }

    func append(_ entry: ClaudeAIQuotaHistoryEntry) {
        var entries = loadAll()
        if let previous = entries.first(where: { $0.accountId == entry.accountId }) {
            let sameState = previous.messagesRemaining == entry.messagesRemaining
                && previous.messagesUsed == entry.messagesUsed
                && previous.resetAt == entry.resetAt
                && previous.sessionHealth == entry.sessionHealth
            if sameState {
                return
            }
        }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persist(entries)
    }

    func remove(accountId: UUID) {
        var entries = loadAll()
        entries.removeAll { $0.accountId == accountId }
        persist(entries)
    }

    func resetForTests() {
        cachedEntries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadAll() -> [ClaudeAIQuotaHistoryEntry] {
        if let cachedEntries {
            return cachedEntries
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedEntries = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([ClaudeAIQuotaHistoryEntry].self, from: data)) ?? []
        cachedEntries = decoded
        return decoded
    }

    private func persist(_ entries: [ClaudeAIQuotaHistoryEntry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try AtomicFileWriter.write(data, to: fileURL)
            cachedEntries = entries
        } catch {
            ErrorLogger.shared.log("Failed to persist Claude AI quota history: \(error.localizedDescription)")
        }
    }
}
