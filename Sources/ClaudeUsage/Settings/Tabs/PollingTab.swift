import SwiftUI

// MARK: – Polling Tab

struct PollingTab: View {
    @State private var config = ConfigManager.shared.load()

    private var activeTypes: [AccountType] {
        let seen = NSMutableOrderedSet()
        for acct in config.accounts where acct.isActive {
            seen.add(acct.type.rawValue)
        }
        return seen.array.compactMap { ($0 as? String).flatMap(AccountType.init(rawValue:)) }
    }

    var body: some View {
        Form {
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
}
