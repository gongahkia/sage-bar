import Foundation

final class AutomationCooldownStore {
    static let shared = AutomationCooldownStore()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.claudeusage.automation.cooldowns", qos: .utility)

    private init() {
        fileURL = AppConstants.sharedContainerURL.appendingPathComponent("automation_cooldowns.json")
    }

    func lastFiredAt(ruleID: UUID) -> Date? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            guard let all = try? dec.decode([String: Date].self, from: data) else { return nil }
            return all[ruleID.uuidString]
        }
    }

    func setLastFiredAt(_ date: Date, ruleID: UUID) {
        queue.async {
            var all: [String: Date] = [:]
            if let data = try? Data(contentsOf: self.fileURL) {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                all = (try? dec.decode([String: Date].self, from: data)) ?? [:]
            }
            all[ruleID.uuidString] = date
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(all) else { return }
            try? AtomicFileWriter.write(data, to: self.fileURL)
        }
    }
}
