import SwiftUI

// MARK: – Analytics Tab

struct AnalyticsTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var reportStartDate = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var reportEndDate = Date()
    @State private var selectedGroupLabel = ""
    @State private var selectedLocalAccountID: UUID?
    @State private var actionFeedback = ""

    var body: some View {
        Form {
            if let globalState = ProductStateResolver.analyticsGlobalState(config: config) {
                Section {
                    ProductStateCardView(card: globalState) { action in
                        handleProductStateAction(action)
                    }
                }
            }
            if let setupCard = ProductStateResolver.setupCTA(config: config) {
                Section {
                    ProductStateCardView(card: setupCard) { action in
                        handleProductStateAction(action)
                    }
                }
            }
            Section("Forecast") {
                Toggle("Show spend forecasts", isOn: $config.forecast.enabled)
                Toggle("Show in popover", isOn: $config.forecast.showInPopover)
            }
            Section("History") {
                Toggle("Show monthly view", isOn: $config.analytics.showMonthlyView)
                Toggle("Show hourly heatmap", isOn: $config.analytics.showHeatmap)
            }
            Section("Model Optimizer") {
                Toggle("Show model cost hints", isOn: $config.modelOptimizer.enabled)
                Stepper("Threshold: \(config.modelOptimizer.cheapThresholdTokens) tokens",
                        value: $config.modelOptimizer.cheapThresholdTokens, in: 100...10000, step: 100)
                Text("Flag sessions shorter than N output tokens").font(.caption).foregroundColor(.secondary)
                Toggle("Show in popover", isOn: $config.modelOptimizer.showInPopover)
            }
            Section("Burn Rate Alerts") {
                Toggle("Enable burn-rate alerts", isOn: $config.burnRate.enabled)
                Stepper(
                    "Default threshold: \(String(format: "$%.2f/h", config.burnRate.defaultUSDPerHourThreshold))",
                    value: $config.burnRate.defaultUSDPerHourThreshold,
                    in: 0...1_000,
                    step: 0.5
                )
                Stepper(
                    "Alert cooldown: \(burnRateCooldownMinutesBinding.wrappedValue) min",
                    value: burnRateCooldownMinutesBinding,
                    in: 1...1_440,
                    step: 1
                )
                if !activeAccounts.isEmpty {
                    Text("Per-account threshold overrides").font(.caption).foregroundColor(.secondary)
                    ForEach(activeAccounts) { account in
                        Toggle(
                            "Override \(burnRateLabel(for: account))",
                            isOn: burnRateOverrideEnabledBinding(for: account)
                        )
                        if config.burnRate.perAccountUSDPerHourThreshold[account.id.uuidString] != nil {
                            Stepper(
                                "\(burnRateLabel(for: account)): \(String(format: "$%.2f/h", burnRateOverrideThresholdBinding(for: account).wrappedValue))",
                                value: burnRateOverrideThresholdBinding(for: account),
                                in: 0...1_000,
                                step: 0.5
                            )
                        }
                    }
                }
            }
            Section("Reporting") {
                DatePicker("Start", selection: $reportStartDate, displayedComponents: .date)
                DatePicker("End", selection: $reportEndDate, displayedComponents: .date)
                Text("Range: \(UsageReportingService.intervalLabel(for: reportInterval))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let rangeState = ProductStateResolver.reportingRangeState(accounts: activeAccounts, interval: reportInterval) {
                    ProductStateCardView(card: rangeState) { action in
                        handleProductStateAction(action)
                    }
                }
                HStack {
                    Button("Copy Active Summary") {
                        let didCopy = UsageReportingService.copySummaryToPasteboard(
                            for: activeAccounts,
                            in: reportInterval
                        )
                        setFeedback(didCopy ? "Copied active summary" : "Copy failed")
                    }
                    .disabled(activeAccounts.isEmpty)
                    Button("Export Active CSV") {
                        do {
                            _ = try UsageReportingService.exportCSV(
                                for: activeAccounts,
                                in: reportInterval,
                                filenamePrefix: "sage-bar-active-accounts"
                            )
                            setFeedback("Exported active account CSV")
                        } catch {
                            setFeedback("Export failed")
                        }
                    }
                    .disabled(activeAccounts.isEmpty)
                }
                if !groupLabels.isEmpty {
                    Picker("Group Rollup", selection: $selectedGroupLabel) {
                        Text("Select group").tag("")
                        ForEach(groupLabels, id: \.self) { label in
                            Text(label).tag(label)
                        }
                    }
                    HStack {
                        Button("Copy Group Summary") {
                            let didCopy = UsageReportingService.copyGroupSummaryToPasteboard(
                                groupLabel: selectedGroupLabel,
                                accounts: activeAccounts,
                                interval: reportInterval
                            )
                            setFeedback(didCopy ? "Copied group summary" : "Copy failed")
                        }
                        .disabled(selectedGroupLabel.isEmpty)
                        Button("Export Group Rollup CSV") {
                            do {
                                _ = try UsageReportingService.exportGroupRollupCSV(
                                    for: groupAccounts,
                                    in: reportInterval
                                )
                                setFeedback("Exported group rollup CSV")
                            } catch {
                                setFeedback("Export failed")
                            }
                        }
                        .disabled(groupAccounts.isEmpty)
                    }
                }
                if !groupRollupPreview.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Preview").font(.caption).foregroundColor(.secondary)
                        ForEach(groupRollupPreview, id: \.groupLabel) { row in
                            HStack {
                                Text(row.groupLabel)
                                Spacer()
                                Text(String(format: "$%.2f", row.totalCostUSD))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                }
                if !actionFeedback.isEmpty {
                    Text(actionFeedback)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if !localAccounts.isEmpty {
                Section("Workstreams") {
                    Picker("Local Account", selection: Binding(
                        get: { selectedLocalAccountID ?? localAccounts.first?.id },
                        set: { selectedLocalAccountID = $0 }
                    )) {
                        ForEach(localAccounts) { account in
                            Text(account.displayLabel(among: localAccounts)).tag(Optional(account.id))
                        }
                    }
                    if let selectedWorkstreamAccount {
                        HStack {
                            Button("Copy Workstream Summary") {
                                let didCopy = UsageReportingService.copyWorkstreamSummaryToPasteboard(
                                    for: selectedWorkstreamAccount,
                                    in: reportInterval
                                )
                                setFeedback(didCopy ? "Copied workstream summary" : "Copy failed")
                            }
                            Button("Export Workstream CSV") {
                                do {
                                    _ = try UsageReportingService.exportWorkstreamCSV(
                                        for: selectedWorkstreamAccount,
                                        in: reportInterval
                                    )
                                    setFeedback("Exported workstream CSV")
                                } catch {
                                    setFeedback("Export failed")
                                }
                            }
                        }
                        if workstreamPreview.isEmpty {
                            Text("No workstream-attributed usage in this range yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(workstreamPreview, id: \.workstreamName) { row in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.workstreamName)
                                        Text("\(row.sourceCount) source file(s)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text("\((row.inputTokens + row.outputTokens + row.cacheTokens).formatted())")
                                        .monospacedDigit()
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if selectedGroupLabel.isEmpty {
                selectedGroupLabel = groupLabels.first ?? ""
            }
            if selectedLocalAccountID == nil {
                selectedLocalAccountID = localAccounts.first?.id
            }
        }
        .onChange(of: config.forecast) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.analytics) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.modelOptimizer) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.burnRate) { _ in ConfigManager.shared.save(config) }
        .padding()
    }

    private var activeAccounts: [Account] {
        Account.activeAccounts(in: config)
    }

    private var groupLabels: [String] {
        let labels = activeAccounts.compactMap(\.trimmedGroupLabel)
        return Array(Set(labels)).sorted()
    }

    private var reportInterval: DateInterval {
        UsageReportingService.normalizedDateInterval(start: reportStartDate, end: reportEndDate)
    }

    private var groupAccounts: [Account] {
        guard !selectedGroupLabel.isEmpty else { return [] }
        return activeAccounts.filter {
            ($0.trimmedGroupLabel ?? "Ungrouped").caseInsensitiveCompare(selectedGroupLabel) == .orderedSame
        }
    }

    private var groupRollupPreview: [GroupRollupRow] {
        let scope = groupAccounts.isEmpty ? activeAccounts : groupAccounts
        return UsageReportingService.groupRollupRows(for: scope, in: reportInterval)
    }

    private var localAccounts: [Account] {
        activeAccounts.filter { $0.type.supportsWorkstreamAttribution }
    }

    private var selectedWorkstreamAccount: Account? {
        let fallback = localAccounts.first
        guard let selectedLocalAccountID else { return fallback }
        return localAccounts.first(where: { $0.id == selectedLocalAccountID }) ?? fallback
    }

    private var workstreamPreview: [WorkstreamReportRow] {
        guard let selectedWorkstreamAccount else { return [] }
        return UsageReportingService.workstreamRows(for: selectedWorkstreamAccount, in: reportInterval)
    }

    private var burnRateCooldownMinutesBinding: Binding<Int> {
        Binding(
            get: { max(1, Int((Double(config.burnRate.alertCooldownSeconds) / 60.0).rounded())) },
            set: { config.burnRate.alertCooldownSeconds = max(60, $0 * 60) }
        )
    }

    private func burnRateOverrideEnabledBinding(for account: Account) -> Binding<Bool> {
        Binding(
            get: { config.burnRate.perAccountUSDPerHourThreshold[account.id.uuidString] != nil },
            set: { enabled in
                if enabled {
                    config.burnRate.perAccountUSDPerHourThreshold[account.id.uuidString] = config.burnRate.defaultUSDPerHourThreshold
                } else {
                    config.burnRate.perAccountUSDPerHourThreshold.removeValue(forKey: account.id.uuidString)
                }
            }
        )
    }

    private func burnRateOverrideThresholdBinding(for account: Account) -> Binding<Double> {
        Binding(
            get: { config.burnRate.perAccountUSDPerHourThreshold[account.id.uuidString] ?? config.burnRate.defaultUSDPerHourThreshold },
            set: { config.burnRate.perAccountUSDPerHourThreshold[account.id.uuidString] = max(0, $0) }
        )
    }

    private func burnRateLabel(for account: Account) -> String {
        let trimmed = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(account.type.rawValue)-\(account.id.uuidString.prefix(6))" : trimmed
    }

    private func setFeedback(_ text: String) {
        actionFeedback = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if actionFeedback == text {
                actionFeedback = ""
            }
        }
    }

    private func handleProductStateAction(_ action: ProductStateActionKind) {
        switch action {
        case .runSetupWizard:
            OnboardingWindowController.shared.showWindow(force: true)
        case .openSettings, .openAccountsSettings, .reconnectSettings:
            SettingsWindowController.shared.showWindow()
        case .refreshNow:
            PollingService.shared.forceRefresh()
        case .resetDateRange:
            reportStartDate = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
            reportEndDate = Date()
        case .exportAllTime:
            do {
                _ = try UsageReportingService.exportCSV(
                    for: activeAccounts,
                    in: nil,
                    filenamePrefix: "sage-bar-active-accounts"
                )
                setFeedback("Exported all-time account CSV")
            } catch {
                setFeedback("Export failed")
            }
        case .disableDemoMode:
            SetupExperienceStore.shared.disableDemoMode()
            config = ConfigManager.shared.load()
        }
    }
}
