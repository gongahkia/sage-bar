import SwiftUI

// MARK: – Integrations Tab

struct IntegrationsTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var testResult: String?
    @State private var testing = false

    private var webhookURLError: String? {
        let url = config.webhook.url
        guard !url.isEmpty else { return nil }
        guard let parsed = URL(string: url) else { return "Invalid URL" }
        guard parsed.scheme == "https" else { return "Must use https://" }
        guard let host = parsed.host?.lowercased(), !host.isEmpty else { return "Missing host" }
        let allowed = config.webhook.allowedHosts.map { $0.lowercased() }
        let hostAllowed = allowed.contains(where: { pattern in
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(2))
                return host == suffix || host.hasSuffix("." + suffix)
            }
            return host == pattern
        })
        return hostAllowed ? nil : "Host '\(host)' not in allowedHosts"
    }

    var body: some View {
        Form {
            Toggle("Enable webhook", isOn: $config.webhook.enabled)
            TextField("URL", text: $config.webhook.url)
                .overlay(alignment: .trailing) {
                    if webhookURLError != nil {
                        Image(systemName: "exclamationmark.triangle").foregroundColor(.red).padding(.trailing, 4)
                    }
                }
            if let err = webhookURLError {
                Text(err).font(.caption).foregroundColor(.red)
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

