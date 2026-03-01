import SwiftUI

// MARK: – Integrations Tab

struct IntegrationsTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Toggle("Enable webhook", isOn: $config.webhook.enabled)
            TextField("URL", text: $config.webhook.url)
                .overlay(alignment: .trailing) {
                    if !config.webhook.url.isEmpty && URL(string: config.webhook.url) == nil {
                        Image(systemName: "exclamationmark.triangle").foregroundColor(.red).padding(.trailing, 4)
                    }
                }
            Text("Events").font(.caption).foregroundColor(.secondary)
            ForEach(["threshold","burn_rate","daily_digest","weekly_summary"], id: \.self) { ev in
                Toggle(ev, isOn: Binding(
                    get: { config.webhook.events.contains(ev) },
                    set: { v in
                        if v { config.webhook.events.append(ev) } else { config.webhook.events.removeAll { $0 == ev } }
                    }
                ))
            }
            Button("Send Test Payload") {
                testing = true
                Task {
                    let ws = WebhookService()
                    let r = await ws.sendTest(config: config.webhook)
                    await MainActor.run {
                        testing = false
                        testResult = (try? r.get()) != nil ? "✓ Sent" : "✗ Failed"
                    }
                }
            }.disabled(testing || URL(string: config.webhook.url) == nil)
            if let r = testResult { Text(r).font(.caption) }
        }
        .onChange(of: config.webhook) { _ in ConfigManager.shared.save(config) }
        .padding()
    }
}

