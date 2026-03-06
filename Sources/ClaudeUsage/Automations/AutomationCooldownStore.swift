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
            guard let data = try? Data(contentsOf: fileURL) else { return nil } // file may not exist yet
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            do {
                let all = try dec.decode([String: Date].self, from: data)
                return all[ruleID.uuidString]
            } catch {
                ErrorLogger.shared.log("Cooldown store decode failed: \(error.localizedDescription)", level: "WARN")
                return nil
            }
        }
    }

    func setLastFiredAt(_ date: Date, ruleID: UUID) {
        queue.async {
            var all: [String: Date] = [:]
            if let data = try? Data(contentsOf: self.fileURL) {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                do {
                    all = try dec.decode([String: Date].self, from: data)
                } catch {
                    ErrorLogger.shared.log("Cooldown store decode failed on write path: \(error.localizedDescription)", level: "WARN")
                }
            }
            all[ruleID.uuidString] = date
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            do {
                let data = try enc.encode(all)
                try AtomicFileWriter.write(data, to: self.fileURL)
            } catch {
                ErrorLogger.shared.log("Cooldown store write failed: \(error.localizedDescription)")
            }
        }
    }
}
