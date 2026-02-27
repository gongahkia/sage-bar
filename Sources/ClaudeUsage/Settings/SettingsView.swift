import SwiftUI
import Security

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.2") }
            DisplayTab().tabItem { Label("Display", systemImage: "display") }
            PollingTab().tabItem { Label("Polling", systemImage: "clock") }
            AnalyticsTab().tabItem { Label("Analytics", systemImage: "chart.bar") }
            IntegrationsTab().tabItem { Label("Integrations", systemImage: "link") }
            AutomationsTab().tabItem { Label("Automations", systemImage: "gearshape.2") }
            SyncTab().tabItem { Label("Sync", systemImage: "icloud") }
            CLITab().tabItem { Label("CLI", systemImage: "terminal") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "ladybug") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }.frame(width: 600, height: 480)
    }
}

// MARK: – Accounts Tab

struct AccountsTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var showAddSheet = false
    @State private var deleteTarget: Account?

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(config.accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name).fontWeight(.medium)
                            Text(account.type.rawValue).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { account.isActive },
                            set: { newVal in
                                if let i = config.accounts.firstIndex(where: { $0.id == account.id }) {
                                    config.accounts[i].isActive = newVal
                                    ConfigManager.shared.save(config)
                                }
                            }
                        )).labelsHidden()
                    }
                }.onDelete { idx in
                    for i in idx {
                        let a = config.accounts[i]
                        try? KeychainManager.delete(service: AppConstants.keychainService, account: a.id.uuidString)
                    }
                    config.accounts.remove(atOffsets: idx)
                    ConfigManager.shared.save(config)
                }
            }
            HStack {
                Spacer()
                Button("+") { showAddSheet = true }
            }.padding(.horizontal)
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet { newAccount, key in
                config.accounts.append(newAccount)
                if let key, !key.isEmpty {
                    try? KeychainManager.store(key: key, service: AppConstants.keychainService, account: newAccount.id.uuidString)
                }
                ConfigManager.shared.save(config)
            }
        }
    }
}

struct AddAccountSheet: View {
    var onSave: (Account, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: AccountType = .claudeCode
    @State private var apiKey = ""
    @State private var validating = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account").font(.headline)
            TextField("Name", text: $name)
            Picker("Type", selection: $type) {
                ForEach(AccountType.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            if type == .anthropicAPI {
                SecureField("API Key", text: $apiKey)
                if let err = validationError {
                    Text(err).foregroundColor(.red).font(.caption)
                }
            }
            if type == .claudeAI {
                Text("(coming soon)").foregroundColor(.secondary).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .disabled(name.isEmpty || type == .claudeAI || (type == .anthropicAPI && apiKey.isEmpty))
            }
        }.padding().frame(width: 360)
    }

    private func save() {
        guard type != .claudeAI else { return }
        if type == .anthropicAPI {
            validating = true
            Task {
                let client = AnthropicAPIClient(apiKey: apiKey)
                let valid = await client.validateKey()
                await MainActor.run {
                    validating = false
                    if valid {
                        let a = Account(name: name, type: type)
                        onSave(a, apiKey)
                        dismiss()
                    } else {
                        validationError = "Invalid API key"
                    }
                }
            }
        } else {
            onSave(Account(name: name, type: type), nil)
            dismiss()
        }
    }
}

// MARK: – Display Tab

struct DisplayTab: View {
    @State private var config = ConfigManager.shared.load()

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Style", selection: $config.display.menubarStyle) {
                    Text("Icon only").tag("icon")
                    Text("Show cost").tag("cost")
                    Text("Show tokens").tag("tokens")
                }
                Toggle("Show badge", isOn: $config.display.showBadge)
                Toggle("Compact mode", isOn: $config.display.compactMode)
                Toggle("Dual icon (2 accounts)", isOn: $config.display.dualIcon)
            }
            Section("Sparkline") {
                Toggle("Enable sparkline icon", isOn: $config.sparkline.enabled)
                Picker("Style", selection: $config.sparkline.style) {
                    Text("Cost").tag("cost")
                    Text("Tokens").tag("tokens")
                }
                Stepper("Window: \(config.sparkline.windowHours)h", value: $config.sparkline.windowHours, in: 24...720, step: 24)
                Stepper("Resolution: \(config.sparkline.resolution) pts", value: $config.sparkline.resolution, in: 12...48)
            }
            Section("Hotkey") {
                Toggle("Enable global hotkey", isOn: $config.hotkey.enabled)
                HStack {
                    Text("Binding:")
                    Text(hotkeyLabel).fontWeight(.medium)
                }
            }
        }.onChange(of: config.display) { _ in ConfigManager.shared.save(config) }
         .onChange(of: config.sparkline) { _ in ConfigManager.shared.save(config) }
         .onChange(of: config.hotkey) { _ in ConfigManager.shared.save(config) }
         .padding()
    }

    private var hotkeyLabel: String {
        let mods = config.hotkey.modifiers.map { $0 == "option" ? "⌥" : $0 == "command" ? "⌘" : $0 }.joined()
        return "\(mods)\(config.hotkey.key.uppercased())"
    }
}

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

// MARK: – Analytics Tab

struct AnalyticsTab: View {
    @State private var config = ConfigManager.shared.load()

    var body: some View {
        Form {
            Section("Forecast") {
                Toggle("Show spend forecasts", isOn: $config.forecast.enabled)
                Toggle("Show in popover", isOn: $config.forecast.showInPopover)
                Toggle("Show in TUI", isOn: $config.forecast.showInTUI)
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
        }
        .onChange(of: config.forecast) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.analytics) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.modelOptimizer) { _ in ConfigManager.shared.save(config) }
        .padding()
    }
}

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
            ForEach(["threshold","daily_digest","weekly_summary"], id: \.self) { ev in
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

// MARK: – Automations Tab

struct AutomationsTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var showAdd = false

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(config.automations) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rule.name).fontWeight(.medium)
                            Text("\(rule.triggerType) > \(rule.threshold)").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { v in
                                if let i = config.automations.firstIndex(where: { $0.id == rule.id }) {
                                    config.automations[i].enabled = v
                                    ConfigManager.shared.save(config)
                                }
                            }
                        )).labelsHidden()
                    }
                }.onDelete { idx in
                    config.automations.remove(atOffsets: idx)
                    ConfigManager.shared.save(config)
                }
            }
            Button("+ Add Rule") { showAdd = true }.padding()
        }
        .sheet(isPresented: $showAdd) {
            AddAutomationSheet { rule in
                config.automations.append(rule)
                ConfigManager.shared.save(config)
            }
        }
    }
}

struct AddAutomationSheet: View {
    var onSave: (AutomationRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var triggerType = "cost_gt"
    @State private var threshold = ""
    @State private var shellCommand = ""
    @State private var testOutput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Automation").font(.headline)
            TextField("Name", text: $name)
            Picker("Trigger", selection: $triggerType) {
                Text("Cost >").tag("cost_gt")
                Text("Tokens >").tag("tokens_gt")
            }.pickerStyle(.segmented)
            TextField("Threshold", text: $threshold)
            TextField("Shell command", text: $shellCommand)
            if !testOutput.isEmpty {
                ScrollView { Text(testOutput).font(.system(.caption, design: .monospaced)) }
                    .frame(height: 60).border(Color.gray)
            }
            HStack {
                Button("Run Now (test)") {
                    guard let d = Double(threshold) else { return }
                    let rule = AutomationRule(name: name, triggerType: triggerType, threshold: d, shellCommand: shellCommand)
                    Task {
                        let out = await AutomationEngine.testRun(rule: rule)
                        await MainActor.run { testOutput = out }
                    }
                }.disabled(shellCommand.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let d = Double(threshold), !name.isEmpty, !shellCommand.isEmpty else { return }
                    let rule = AutomationRule(name: name, triggerType: triggerType, threshold: d, shellCommand: shellCommand)
                    onSave(rule)
                    dismiss()
                }
            }
        }.padding().frame(width: 380)
    }
}

// MARK: – Sync Tab

struct SyncTab: View {
    @State private var config = ConfigManager.shared.load()
    @StateObject private var syncMgr = iCloudSyncManager.shared

    var body: some View {
        Form {
            if config.iCloudSync.enabled {
                Toggle("Enable iCloud sync", isOn: $config.iCloudSync.enabled)
                Toggle("Local only", isOn: $config.iCloudSync.localOnly)
                Text("Last sync: \(syncMgr.lastSyncDate.map { $0.formatted() } ?? "Never")").font(.caption)
                Text(syncMgr.syncState.label).font(.caption).foregroundColor(.secondary)
                Button("Sync Now") { Task { await iCloudSyncManager.shared.syncNow() } }
            } else {
                Toggle("Enable iCloud sync", isOn: $config.iCloudSync.enabled)
                Text("iCloud sync is off — data stays local only").foregroundColor(.secondary).font(.caption)
                Text("Requires iCloud Drive").foregroundColor(.secondary).font(.caption)
            }
        }
        .onChange(of: config.iCloudSync) { _ in ConfigManager.shared.save(config) }
        .padding()
    }
}

// MARK: – CLI Tab

struct CLITab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var copyFeedback = false

    private let snippet = "claude-usage"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLI Binary").font(.headline)
            Text("Install the claude-usage binary to access usage data from the terminal.")
            Button("Install to /usr/local/bin") { installCLI() }

            Divider()

            Text("Shell Integration").font(.headline)
            HStack {
                TextField("", text: .constant(snippet)).textFieldStyle(.roundedBorder).disabled(true)
                Button(copyFeedback ? "Copied!" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyFeedback = false }
                }
            }

            Divider()
            Text("TUI Layout").font(.headline)
            List {
                ForEach(Array(config.tui.layout.enumerated()), id: \.element) { _, field in
                    Text(field)
                }
                .onMove { from, to in
                    config.tui.layout.move(fromOffsets: from, toOffset: to)
                    ConfigManager.shared.save(config)
                }
            }.frame(height: 200)
        }.padding()
    }

    private func installCLI() {
        // copy current binary to /usr/local/bin/claude-usage via shell
        guard let bin = Bundle.main.executableURL else { return }
        let dest = URL(fileURLWithPath: "/usr/local/bin/claude-usage")
        let script = "cp '\(bin.path)' '\(dest.path)' && chmod +x '\(dest.path)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }
}

// MARK: – About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Claude Usage").font(.largeTitle).fontWeight(.bold)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundColor(.secondary)
            Text("Data sources: Claude Code local logs, Anthropic Workspace API")
                .font(.caption).multilineTextAlignment(.center)
            Link("GitHub", destination: URL(string: "https://github.com")!)
        }.padding()
    }
}
