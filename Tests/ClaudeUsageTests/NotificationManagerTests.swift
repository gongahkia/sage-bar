import XCTest
@testable import ClaudeUsage

final class NotificationManagerTests: XCTestCase {
    private func snap(accountId: UUID, cost: Double) -> UsageSnapshot {
        UsageSnapshot(
            accountId: accountId,
            timestamp: Date(),
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: cost,
            modelBreakdown: []
        )
    }

    func testThresholdNotificationOnlyMarksOncePerAccountPerDay() {
        let account = Account(name: "threshold", type: .anthropicAPI, isActive: true)
        let key = "thresholdNotified_\(account.id.uuidString)"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let webhook = WebhookConfig(enabled: false, url: "", events: [], payloadTemplate: nil)
        let first = snap(accountId: account.id, cost: 25)
        NotificationManager.shared.checkThreshold(snapshot: first, account: account, limitUSD: 10, webhookConfig: webhook)
        guard let firstMarked = UserDefaults.standard.object(forKey: key) as? Date else {
            XCTFail("threshold marker not set after first trigger")
            return
        }

        let second = snap(accountId: account.id, cost: 30)
        NotificationManager.shared.checkThreshold(snapshot: second, account: account, limitUSD: 10, webhookConfig: webhook)
        let secondMarked = UserDefaults.standard.object(forKey: key) as? Date
        XCTAssertEqual(secondMarked?.timeIntervalSince1970 ?? -1, firstMarked.timeIntervalSince1970, accuracy: 0.001)
    }

    func testThresholdNotificationRearmsNextDay() {
        let account = Account(name: "threshold-next-day", type: .anthropicAPI, isActive: true)
        let key = "thresholdNotified_\(account.id.uuidString)"
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        UserDefaults.standard.set(yesterday, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let webhook = WebhookConfig(enabled: false, url: "", events: [], payloadTemplate: nil)
        let current = snap(accountId: account.id, cost: 40)
        NotificationManager.shared.checkThreshold(snapshot: current, account: account, limitUSD: 10, webhookConfig: webhook)

        let marked = UserDefaults.standard.object(forKey: key) as? Date
        XCTAssertNotNil(marked)
        if let marked {
            XCTAssertTrue(Calendar.current.isDateInToday(marked))
        }
    }
}
