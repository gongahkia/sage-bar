import AppKit
import Foundation

enum AppleScriptUsageBridge {
    private final class BlockingBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?

        func store(_ value: T) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> T? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func getTodayUsageRecords(config: Config = ConfigManager.shared.load()) -> [[String: Any]] {
        blocking {
            var rows: [[String: Any]] = []
            for account in UsageAccessService.activeAccounts(config: config) {
                let payload = await UsageAccessService.currentUsage(for: account, config: config)
                rows.append([
                    "accountName": payload.accountName,
                    "inputTokens": payload.totalInputTokens,
                    "outputTokens": payload.totalOutputTokens,
                    "costUSD": payload.totalCostUSD,
                    "lastUpdated": payload.lastUpdated ?? Date(),
                ])
            }
            return rows
        }
    }

    static func getCurrentUsage(
        accountIdentifierOrName: String?,
        config: Config = ConfigManager.shared.load(),
        userDefaults: UserDefaults = .standard
    ) -> [String: Any]? {
        guard let account = UsageAccessService.resolveAccount(
            identifierOrName: accountIdentifierOrName,
            config: config,
            userDefaults: userDefaults
        ) else {
            return nil
        }
        return blocking {
            let payload = await UsageAccessService.currentUsage(for: account, config: config)
            return [
                "accountName": payload.accountName,
                "totalInputTokens": payload.totalInputTokens,
                "totalOutputTokens": payload.totalOutputTokens,
                "totalCostUSD": payload.totalCostUSD,
                "lastUpdated": payload.lastUpdated as Any,
            ]
        }
    }

    static func getForecast(
        accountIdentifierOrName: String?,
        config: Config = ConfigManager.shared.load(),
        userDefaults: UserDefaults = .standard
    ) -> String {
        guard let account = UsageAccessService.resolveAccount(
            identifierOrName: accountIdentifierOrName,
            config: config,
            userDefaults: userDefaults
        ) else {
            return "No forecast data available."
        }
        return blocking {
            await UsageAccessService.forecastSummary(for: account)
        }
    }

    static func getUsageSummary(
        accountIdentifierOrName: String?,
        config: Config = ConfigManager.shared.load(),
        userDefaults: UserDefaults = .standard
    ) -> String {
        let account = UsageAccessService.resolveAccount(
            identifierOrName: accountIdentifierOrName,
            config: config,
            userDefaults: userDefaults
        )
        if let account {
            return UsageReportingService.summaryText(for: account, among: UsageAccessService.activeAccounts(config: config))
        }
        return UsageReportingService.summaryText(for: UsageAccessService.activeAccounts(config: config))
    }

    static func getDiagnosticsSnapshot(
        config: Config = ConfigManager.shared.load(),
        maxErrorLines: Int = 120
    ) -> String {
        blocking {
            await UsageAccessService.diagnosticsSnapshotJSON(
                config: config,
                maxErrorLines: maxErrorLines
            )
        }
    }

    static func triggerPoll() -> Bool {
        blocking {
            await PollingService.shared.pollOnce()
            return await MainActor.run { PollingService.shared.lastFetchError == nil }
        }
    }

    static func refresh() {
        Task { @MainActor in
            PollingService.shared.requestFollowUpRefresh()
        }
    }

    private static func blocking<T>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = BlockingBox<T>()
        Task {
            result.store(await operation())
            semaphore.signal()
        }
        semaphore.wait()
        return result.load()!
    }
}

@objc(GetTodayUsageScriptCommand)
final class GetTodayUsageScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppleScriptUsageBridge.getTodayUsageRecords()
    }
}

@objc(GetCurrentUsageScriptCommand)
final class GetCurrentUsageScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppleScriptUsageBridge.getCurrentUsage(accountIdentifierOrName: evaluatedArguments?["account"] as? String)
    }
}

@objc(GetForecastScriptCommand)
final class GetForecastScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppleScriptUsageBridge.getForecast(accountIdentifierOrName: evaluatedArguments?["account"] as? String)
    }
}

@objc(GetUsageSummaryScriptCommand)
final class GetUsageSummaryScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppleScriptUsageBridge.getUsageSummary(accountIdentifierOrName: evaluatedArguments?["account"] as? String)
    }
}

@objc(GetDiagnosticsSnapshotScriptCommand)
final class GetDiagnosticsSnapshotScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppleScriptUsageBridge.getDiagnosticsSnapshot()
    }
}

@objc(RefreshScriptCommand)
final class RefreshScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppleScriptUsageBridge.refresh()
        return nil
    }
}

@objc(TriggerPollScriptCommand)
final class TriggerPollScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppleScriptUsageBridge.triggerPoll()
    }
}
