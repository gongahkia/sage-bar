import Foundation
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    func requestPermission() {
        guard !UserDefaults.standard.bool(forKey: "notifPermissionRequested") else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            UserDefaults.standard.set(true, forKey: "notifPermissionRequested")
            UserDefaults.standard.set(granted, forKey: "notifPermissionGranted")
        }
    }

    /// posts local notification if snapshot.totalCostUSD > limitUSD; throttled once per day per account
    func checkThreshold(snapshot: UsageSnapshot, account: Account, limitUSD: Double, webhookConfig: WebhookConfig) {
        guard snapshot.totalCostUSD > limitUSD else { return }
        let key = "thresholdNotified_\(account.id.uuidString)"
        if let prev = UserDefaults.standard.object(forKey: key) as? Date,
           Calendar.current.isDateInToday(prev) { return }
        UserDefaults.standard.set(Date(), forKey: key)

        let cost = String(format: "$%.2f", snapshot.totalCostUSD)
        let limit = String(format: "$%.2f", limitUSD)
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage Alert"
        content.body = "Account '\(account.name)' reached \(cost) today (limit: \(limit))"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)

        // webhook
        if webhookConfig.enabled, webhookConfig.events.contains("threshold") {
            let ws = WebhookService()
            Task { try? await ws.send(event: .thresholdBreached(limitUSD: limitUSD), snapshot: snapshot, config: webhookConfig) }
        }
    }
}
