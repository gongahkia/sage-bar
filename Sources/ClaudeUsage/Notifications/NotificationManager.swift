import Foundation
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    func requestPermission() {
        guard !UserDefaults.standard.bool(forKey: "notifPermissionRequested") else { return }
        guard let center = userNotificationCenterIfAvailable() else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
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
        content.title = "Sage Bar Alert"
        content.body = "Account '\(account.name)' reached \(cost) today (limit: \(limit))"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        if let center = userNotificationCenterIfAvailable() {
            center.add(req)
        }

        // webhook
        if webhookConfig.enabled, webhookConfig.events.contains("threshold") {
            let ws = WebhookService()
            Task {
                do {
                    try await ws.send(event: .thresholdBreached(limitUSD: limitUSD), snapshot: snapshot, config: webhookConfig)
                } catch {
                    ErrorLogger.shared.log(
                        "Threshold webhook failed for account \(account.id.uuidString): \(error.localizedDescription)",
                        level: "WARN"
                    )
                }
            }
        }
    }

    /// posts local notification if burn-rate exceeds threshold; throttled by configurable cooldown per account
    func checkBurnRate(
        account: Account,
        burnRateUSDPerHour: Double,
        thresholdUSDPerHour: Double,
        cooldownSeconds: Int,
        webhookConfig: WebhookConfig,
        now: Date = Date()
    ) {
        guard thresholdUSDPerHour > 0, burnRateUSDPerHour > thresholdUSDPerHour else { return }
        let key = "burnRateNotified_\(account.id.uuidString)"
        let cooldown = max(0, cooldownSeconds)
        if let prev = UserDefaults.standard.object(forKey: key) as? Date,
           now.timeIntervalSince(prev) < TimeInterval(cooldown) {
            return
        }
        UserDefaults.standard.set(now, forKey: key)

        let burn = String(format: "$%.2f/h", burnRateUSDPerHour)
        let threshold = String(format: "$%.2f/h", thresholdUSDPerHour)
        let content = UNMutableNotificationContent()
        content.title = "Sage Bar Burn-Rate Alert"
        content.body = "Account '\(account.name)' is burning at \(burn) (threshold: \(threshold))"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        if let center = userNotificationCenterIfAvailable() {
            center.add(req)
        }

        if webhookConfig.enabled,
           webhookConfig.events.contains("burn_rate") || webhookConfig.events.contains("threshold") {
            let ws = WebhookService()
            let snapshot = UsageSnapshot(
                accountId: account.id,
                timestamp: now,
                inputTokens: 0,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                totalCostUSD: burnRateUSDPerHour,
                modelBreakdown: [ModelUsage(modelId: "burn-rate", inputTokens: 0, outputTokens: 0, costUSD: burnRateUSDPerHour)],
                costConfidence: .estimated
            )
            Task {
                do {
                    try await ws.send(
                        event: .burnRateBreached(
                            thresholdUSDPerHour: thresholdUSDPerHour,
                            burnRateUSDPerHour: burnRateUSDPerHour
                        ),
                        snapshot: snapshot,
                        config: webhookConfig
                    )
                } catch {
                    ErrorLogger.shared.log(
                        "Burn-rate webhook failed for account \(account.id.uuidString): \(error.localizedDescription)",
                        level: "WARN"
                    )
                }
            }
        }
    }

    func checkClaudeAILowQuota(
        account: Account,
        status: ClaudeAIStatus,
        config: ClaudeAIConfig,
        now: Date = Date()
    ) {
        guard config.notifyOnLowMessages else { return }
        guard status.messagesRemaining <= config.lowMessagesThreshold else { return }
        let windowKey = claudeAIResetWindowKey(status: status, now: now)
        let defaultsKey = "claudeAILowQuotaNotified_\(account.id.uuidString)"
        if UserDefaults.standard.string(forKey: defaultsKey) == windowKey {
            return
        }
        UserDefaults.standard.set(windowKey, forKey: defaultsKey)

        let content = UNMutableNotificationContent()
        content.title = "Sage Bar Claude AI Alert"
        if let resetAt = status.resetAt {
            content.body = "Account '\(account.name)' has \(status.messagesRemaining) messages left until \(resetAt.formatted(date: .abbreviated, time: .shortened))."
        } else {
            content.body = "Account '\(account.name)' has \(status.messagesRemaining) messages left."
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        if let center = userNotificationCenterIfAvailable() {
            center.add(req)
        }
    }

    private func userNotificationCenterIfAvailable() -> UNUserNotificationCenter? {
        // XCTest on macOS CLI can crash when touching UNUserNotificationCenter.current().
        guard !isRunningUnderXCTest else {
            return nil
        }
        // `swift run` launches an unbundled executable; UserNotifications can assert in that context.
        guard hasValidAppBundleRuntimeForUserNotifications else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    private var hasValidAppBundleRuntimeForUserNotifications: Bool {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            return false
        }
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return false
        }
        return true
    }

    private var isRunningUnderXCTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || ProcessInfo.processInfo.processName == "xctest"
            || NSClassFromString("XCTestCase") != nil
    }

    private func claudeAIResetWindowKey(status: ClaudeAIStatus, now: Date) -> String {
        if let resetAt = status.resetAt {
            return SharedDateFormatters.iso8601InternetDateTime.string(from: resetAt)
        }
        let startOfDay = Calendar.current.startOfDay(for: now)
        return SharedDateFormatters.iso8601FullDate.string(from: startOfDay)
    }
}
