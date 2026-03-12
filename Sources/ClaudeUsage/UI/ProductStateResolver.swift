import Foundation

enum ProductStateResolver {
    static func setupCTA(
        config: Config = ConfigManager.shared.load(),
        setupExperience: SetupExperienceStore = .shared
    ) -> ProductStateCard? {
        guard setupExperience.shouldShowFinishSetupCTA(config: config) else { return nil }
        if setupExperience.state.demoModeEnabled {
            return ProductStateCard(
                title: "Demo mode is active",
                message: "Sage Bar is showing sample guidance until you connect a real account.",
                detail: "Connect your first account to replace demo-mode empty states.",
                tone: .info,
                primaryAction: ProductStateAction(title: "Run Setup Wizard", kind: .runSetupWizard),
                secondaryAction: ProductStateAction(title: "Turn Off Demo", kind: .disableDemoMode)
            )
        }
        return ProductStateCard(
            title: "Finish setup",
            message: "Validate your first account so Sage Bar can show real usage, alerts, and reports.",
            detail: nil,
            tone: .info,
            primaryAction: ProductStateAction(title: "Run Setup Wizard", kind: .runSetupWizard),
            secondaryAction: ProductStateAction(title: "Open Settings", kind: .openSettings)
        )
    }

    static func popoverGlobalState(
        config: Config = ConfigManager.shared.load(),
        setupExperience: SetupExperienceStore = .shared
    ) -> ProductStateCard? {
        let activeAccounts = Account.activeAccounts(in: config)
        guard activeAccounts.isEmpty else { return nil }
        if setupExperience.state.demoModeEnabled {
            return ProductStateCard(
                title: "Demo mode preview",
                message: "Sample spend today: $12.43 across 18,400 tokens and 4 providers.",
                detail: "Connect an account to replace demo mode with live usage data.",
                tone: .info,
                primaryAction: ProductStateAction(title: "Run Setup Wizard", kind: .runSetupWizard),
                secondaryAction: ProductStateAction(title: "Turn Off Demo", kind: .disableDemoMode)
            )
        }
        return ProductStateCard(
            title: "No active accounts",
            message: "Add and validate an account to start tracking usage in the menu bar.",
            detail: nil,
            tone: .info,
            primaryAction: ProductStateAction(title: "Run Setup Wizard", kind: .runSetupWizard),
            secondaryAction: ProductStateAction(title: "Open Settings", kind: .openSettings)
        )
    }

    static func accountState(
        for account: Account,
        latestSnapshot: UsageSnapshot?,
        lastSuccess: Date?,
        claudeAIStatus: ClaudeAIStatus?,
        fetchErrorMessage: String?,
        fetchErrorUpdatedAt: Date?,
        pollIntervalSeconds: Int,
        now: Date = Date()
    ) -> ProductStateCard? {
        if account.type.supportsWorkstreamAttribution,
           let localStatus = LocalProviderLocator.status(for: account),
           !localStatus.isAvailable {
            return ProductStateCard(
                title: "Local source missing",
                message: "Sage Bar cannot read \(account.type.displayName) data from the expected directory.",
                detail: localStatus.displayPath,
                tone: .warning,
                primaryAction: ProductStateAction(title: "Open Accounts Settings", kind: .openAccountsSettings),
                secondaryAction: ProductStateAction(title: "Run Setup Wizard", kind: .runSetupWizard)
            )
        }

        if let status = claudeAIStatus, status.sessionHealth == .reauthRequired {
            return ProductStateCard(
                title: "Claude AI needs re-authentication",
                message: "Your claude.ai session token is no longer valid.",
                detail: fetchErrorUpdatedAt.map {
                    "Last issue: \($0.formatted(date: .omitted, time: .shortened))"
                },
                tone: .warning,
                primaryAction: ProductStateAction(title: "Reconnect in Settings", kind: .reconnectSettings),
                secondaryAction: ProductStateAction(title: "Refresh now", kind: .refreshNow)
            )
        }

        if let fetchErrorMessage,
           isCredentialFailure(message: fetchErrorMessage, accountType: account.type) {
            return ProductStateCard(
                title: "Connection needs attention",
                message: "Sage Bar could not validate this account's credentials or permissions.",
                detail: fetchErrorUpdatedAt.map {
                    "Last issue: \($0.formatted(date: .omitted, time: .shortened))"
                },
                tone: .warning,
                primaryAction: ProductStateAction(title: "Reconnect in Settings", kind: .reconnectSettings),
                secondaryAction: ProductStateAction(title: "Refresh now", kind: .refreshNow)
            )
        }

        if latestSnapshot == nil && lastSuccess == nil {
            return ProductStateCard(
                title: "No usage yet",
                message: "This account is configured, but Sage Bar has not fetched any usage data yet.",
                detail: fetchErrorMessage,
                tone: .info,
                primaryAction: ProductStateAction(title: "Refresh now", kind: .refreshNow),
                secondaryAction: ProductStateAction(title: "Open Settings", kind: .openSettings)
            )
        }

        if let latestSnapshot {
            let staleThreshold = TimeInterval(max(60, pollIntervalSeconds)) * 2
            let age = now.timeIntervalSince(latestSnapshot.timestamp)
            if latestSnapshot.isStale || age > staleThreshold {
                return ProductStateCard(
                    title: "Using stale data",
                    message: "Sage Bar is showing the latest cached snapshot while it waits for a fresh fetch.",
                    detail: "Last snapshot: \(latestSnapshot.timestamp.formatted(date: .omitted, time: .shortened))",
                    tone: .warning,
                    primaryAction: ProductStateAction(title: "Refresh now", kind: .refreshNow),
                    secondaryAction: ProductStateAction(title: "Open Settings", kind: .openSettings)
                )
            }
        }

        return nil
    }

    static func analyticsGlobalState(
        config: Config = ConfigManager.shared.load(),
        setupExperience: SetupExperienceStore = .shared
    ) -> ProductStateCard? {
        if !config.analytics.enabled {
            return ProductStateCard(
                title: "Analytics disabled",
                message: "Enable analytics to view history, heatmaps, and reporting exports.",
                detail: nil,
                tone: .info,
                primaryAction: ProductStateAction(title: "Open Settings", kind: .openSettings),
                secondaryAction: nil
            )
        }
        return popoverGlobalState(config: config, setupExperience: setupExperience)
    }

    static func reportingRangeState(accounts: [Account], interval: DateInterval) -> ProductStateCard? {
        guard !accounts.isEmpty else { return nil }
        let rows = UsageReportingService.reportRows(for: accounts, in: interval)
        guard rows.allSatisfy({ $0.inputTokens == 0 && $0.outputTokens == 0 && $0.cacheTokens == 0 && $0.totalCostUSD == 0 }) else {
            return nil
        }
        return ProductStateCard(
            title: "No data in this date range",
            message: "Try a wider range or export all available usage data.",
            detail: UsageReportingService.intervalLabel(for: interval),
            tone: .info,
            primaryAction: ProductStateAction(title: "Reset date range", kind: .resetDateRange),
            secondaryAction: ProductStateAction(title: "Export all time", kind: .exportAllTime)
        )
    }

    private static func isCredentialFailure(message: String, accountType: AccountType) -> Bool {
        let normalized = message.lowercased()
        if accountType == .claudeAI {
            return normalized.contains("session token")
                || normalized.contains("session unauthorized")
                || normalized.contains("session forbidden")
        }
        return normalized.contains("invalid")
            || normalized.contains("no openai admin key")
            || normalized.contains("no windsurf service key")
            || normalized.contains("no github token")
            || normalized.contains("no api key")
            || normalized.contains("permissions")
            || normalized.contains("token")
            || normalized.contains("keychain failure")
    }
}
