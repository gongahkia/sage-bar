import SwiftUI

// MARK: – Polling Tab

struct PollingTab: View {
    @State private var config = ConfigManager.shared.load()
    @ObservedObject private var setupExperience = SetupExperienceStore.shared

    private var activeTypes: [AccountType] {
        let seen = NSMutableOrderedSet()
        for acct in config.accounts where acct.isActive {
            seen.add(acct.type.rawValue)
        }
        return seen.array.compactMap { ($0 as? String).flatMap(AccountType.init(rawValue:)) }
    }

    var body: some View {
        Form {
            if let globalState = ProductStateResolver.popoverGlobalState(config: config, setupExperience: setupExperience) {
                Section {
                    ProductStateCardView(card: globalState) { action in
                        handleProductStateAction(action)
                    }
                }
            }
            if let setupCard = ProductStateResolver.setupCTA(config: config, setupExperience: setupExperience) {
                Section {
                    ProductStateCardView(card: setupCard) { action in
                        handleProductStateAction(action)
                    }
                }
            }
            Section("Global Fallback Interval") {
                Slider(value: Binding(
                    get: { Double(config.pollIntervalSeconds) },
                    set: { config.pollIntervalSeconds = Int($0) }
                ), in: 60...3600, step: 60)
                Text("Every \(config.pollIntervalSeconds / 60) min — used when no per-provider interval is set")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            Section("Per-Provider Intervals") {
                if activeTypes.isEmpty {
                    Text("No active accounts").foregroundColor(.secondary)
                }
                ForEach(activeTypes, id: \.self) { type in
                    let seconds = config.providerPolling.interval(for: type)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(type.displayName).font(.headline)
                        Slider(value: Binding(
                            get: { Double(seconds) },
                            set: { config.providerPolling.setInterval(Int($0), for: type) }
                        ), in: 60...3600, step: 60)
                        Text(intervalLabel(seconds))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onChange(of: config.pollIntervalSeconds) { _ in save() }
        .onChange(of: config.providerPolling) { _ in save() }
        .padding()
    }

    private func save() {
        ConfigManager.shared.save(config)
        Task { @MainActor in PollingService.shared.start(config: config) }
    }

    private func intervalLabel(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return "Every \(seconds / 3600) hr"
        }
        let mins = seconds / 60
        return "Every \(mins) min\(mins == 1 ? "" : "")"
    }

    private func handleProductStateAction(_ action: ProductStateActionKind) {
        switch action {
        case .runSetupWizard:
            OnboardingWindowController.shared.showWindow(force: true)
        case .refreshNow:
            Task { @MainActor in PollingService.shared.forceRefresh() }
        case .disableDemoMode:
            SetupExperienceStore.shared.disableDemoMode()
        case .openSettings, .openAccountsSettings, .reconnectSettings, .resetDateRange, .exportAllTime:
            break
        }
    }
}
