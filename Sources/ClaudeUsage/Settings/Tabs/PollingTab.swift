import SwiftUI

// MARK: – Polling Tab

struct PollingTab: View {
    @State private var config = ConfigManager.shared.load()

    var body: some View {
        Form {
            Slider(value: Binding(
                get: { Double(config.pollIntervalSeconds) },
                set: { config.pollIntervalSeconds = Int($0) }
            ), in: 60...3600, step: 60)
            Text("Every \(config.pollIntervalSeconds / 60) minute\(config.pollIntervalSeconds / 60 == 1 ? "" : "s")")
                .foregroundColor(.secondary)
        }
        .onChange(of: config.pollIntervalSeconds) { _ in
            ConfigManager.shared.save(config)
            Task { @MainActor in PollingService.shared.start(config: config) }
        }
        .padding()
    }
}

