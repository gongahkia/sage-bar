import Foundation

struct AutomationRunRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var ruleID: UUID
    var ruleName: String
    var accountID: UUID?
    var accountName: String?
    var timestamp: Date
    var success: Bool
    var dryRun: Bool
    var message: String

    init(
        ruleID: UUID,
        ruleName: String,
        accountID: UUID?,
        accountName: String?,
        timestamp: Date = Date(),
        success: Bool,
        dryRun: Bool,
        message: String
    ) {
        self.id = UUID()
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.accountID = accountID
        self.accountName = accountName
        self.timestamp = timestamp
        self.success = success
        self.dryRun = dryRun
        self.message = message
    }
}

actor AutomationRunHistoryStore {
    static let shared = AutomationRunHistoryStore()

    private let fileURL: URL
    private var cachedRecords: [AutomationRunRecord]?
    private let maxRecords = 200

    init(fileURL: URL = AppConstants.sharedContainerURL.appendingPathComponent("automation_run_history.json")) {
        self.fileURL = fileURL
    }

    func recentRecords(limit: Int = 50) -> [AutomationRunRecord] {
        Array(loadAll().prefix(max(0, limit)))
    }

    func records(for ruleID: UUID, limit: Int = 10) -> [AutomationRunRecord] {
        Array(loadAll().filter { $0.ruleID == ruleID }.prefix(max(0, limit)))
    }

    func append(_ record: AutomationRunRecord) {
        var records = loadAll()
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
        persist(records)
    }

    func resetForTests() {
        cachedRecords = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadAll() -> [AutomationRunRecord] {
        if let cachedRecords {
            return cachedRecords
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedRecords = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([AutomationRunRecord].self, from: data)) ?? []
        cachedRecords = decoded
        return decoded
    }

    private func persist(_ records: [AutomationRunRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try AtomicFileWriter.write(data, to: fileURL)
            cachedRecords = records
            awaitMainActor {
                NotificationCenter.default.post(name: .automationRunHistoryDidChange, object: nil)
            }
        } catch {
            ErrorLogger.shared.log("Failed to persist automation run history: \(error.localizedDescription)")
        }
    }

    private func awaitMainActor(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }
}

extension Notification.Name {
    static let automationRunHistoryDidChange = Notification.Name("AutomationRunHistoryDidChange")
}
