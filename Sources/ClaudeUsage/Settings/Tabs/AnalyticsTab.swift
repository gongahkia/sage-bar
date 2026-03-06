import SwiftUI

// MARK: – Analytics Tab

struct AnalyticsTab: View {
    @State private var config = ConfigManager.shared.load()

    var body: some View {
        Form {
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
        }
        .onChange(of: config.forecast) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.analytics) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.modelOptimizer) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.burnRate) { _ in ConfigManager.shared.save(config) }
        .padding()
    }

    private var activeAccounts: [Account] {
        config.accounts.filter { $0.isActive }
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
}

