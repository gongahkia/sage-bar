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
            HotkeyTab().tabItem { Label("Hotkey", systemImage: "keyboard") }
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
    @State private var connectionStatus: [UUID: String] = [:] // task 88
    @State private var connectionTesting: Set<UUID> = []
    @ObservedObject private var polling = PollingService.shared

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(config.accounts) { account in
                    VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name).fontWeight(.medium)
                            Text(account.type.rawValue).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        // task 88: Test Connection button
                        if connectionTesting.contains(account.id) {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Button("Test") {
                                connectionTesting.insert(account.id)
                                connectionStatus.removeValue(forKey: account.id)
                                Task {
                                    let result = await testConnection(account: account)
                                    connectionStatus[account.id] = result
                                    connectionTesting.remove(account.id)
                                }
                            }.font(.caption).buttonStyle(.bordered)
                        }
                        Toggle("", isOn: Binding(
                            get: { account.isActive },
                            set: { newVal in
                                if let i = config.accounts.firstIndex(where: { $0.id == account.id }) {
                                    config.accounts[i].isActive = newVal
                                    ConfigManager.shared.save(config)
                                }
                            }
                        )).labelsHidden()
                    } // HStack
                    if let status = connectionStatus[account.id] { // task 88: inline result
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(status.hasPrefix("✓") ? .green : .red)
                            .padding(.leading, 4)
                    }
                    if let health = polling.providerHealthScore(for: account.id) {
                        Text("Provider health: \(Int((health * 100).rounded()))%")
                            .font(.caption2)
                            .foregroundColor(health >= 0.8 ? .green : (health >= 0.5 ? .orange : .red))
                            .padding(.leading, 4)
                    }
                    if let i = config.accounts.firstIndex(where: { $0.id == account.id }) {
                        Stepper("Order: \(config.accounts[i].order)", value: Binding(
                            get: { config.accounts[i].order },
                            set: { newVal in
                                config.accounts[i].order = newVal
                                ConfigManager.shared.save(config)
                            }
                        ), in: -100...100)
                        .font(.caption)
                    }
                    } // outer VStack
                }.onDelete { idx in
                    for i in idx {
                        let a = config.accounts[i]
                        try? KeychainManager.delete(service: AppConstants.keychainService, account: a.id.uuidString)
                        if a.type == .claudeAI {
                            try? KeychainManager.delete(
                                service: AppConstants.keychainSessionTokenService,
                                account: a.id.uuidString
                            )
                        }
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

    // task 88: test connection per account type
    private func testConnection(account: Account) async -> String {
        guard account.type.capabilities.supportsConnectionTest else {
            return "✗ Test connection unsupported for this provider type"
        }
        switch account.type {
        case .claudeCode:
            return "✓ OK (local logs, no API)"
        case .codex:
            return "✓ OK (local Codex logs, no API)"
        case .gemini:
            return "✓ OK (local Gemini CLI logs, no API)"
        case .openAIOrg:
            guard let raw = try? KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString),
                  let adminKey = ProviderCredentialCodec.openAIAdminKey(from: raw) else {
                return "✗ No OpenAI admin key stored"
            }
            let client = OpenAIOrgUsageClient(adminAPIKey: adminKey)
            return await client.validateAccess() ? "✓ OK" : "✗ Fetch failed (check admin key/org permissions)"
        case .windsurfEnterprise:
            guard let raw = try? KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString),
                  let payload = ProviderCredentialCodec.windsurf(from: raw) else {
                return "✗ Missing Windsurf service key payload"
            }
            let client = WindsurfEnterpriseClient(serviceKey: payload.serviceKey, groupName: payload.groupName)
            return await client.validateAccess() ? "✓ OK" : "✗ Fetch failed (check service key/group)"
        case .githubCopilot:
            guard let raw = try? KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString),
                  let payload = ProviderCredentialCodec.copilot(from: raw) else {
                return "✗ Missing GitHub Copilot token/org payload"
            }
            let client = GitHubCopilotMetricsClient(token: payload.token, organization: payload.organization)
            return await client.validateAccess() ? "✓ OK" : "✗ Fetch failed (check token scope/org access)"
        case .anthropicAPI:
            guard let key = try? KeychainManager.retrieve(service: AppConstants.keychainService, account: account.id.uuidString) else {
                return "✗ No API key stored"
            }
            let client = AnthropicAPIClient(apiKey: key)
            do {
                let end = Date(); let start = Calendar.current.date(byAdding: .day, value: -1, to: end)!
                _ = try await client.fetchUsage(startDate: start, endDate: end)
                return "✓ OK"
            } catch {
                return "✗ \(error.localizedDescription)"
            }
        case .claudeAI:
            guard let token = try? KeychainManager.retrieve(service: AppConstants.keychainSessionTokenService, account: account.id.uuidString) else {
                return "✗ No session token stored"
            }
            let client = ClaudeAIClient(sessionToken: token)
            let result = await client.fetchUsage()
            return result != nil ? "✓ OK" : "✗ Fetch failed (check session token)"
        }
    }
}

struct AddAccountSheet: View {
    var onSave: (Account, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: AccountType = .claudeCode
    @State private var apiKey = ""
    @State private var sessionToken = ""
    @State private var openAIAdminKey = ""
    @State private var windsurfServiceKey = ""
    @State private var windsurfGroupName = ""
    @State private var githubToken = ""
    @State private var githubOrganization = ""
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
            if type == .openAIOrg {
                SecureField("OpenAI Admin Key", text: $openAIAdminKey)
                Text("Requires an OpenAI admin key with organization usage/cost API access.")
                    .font(.caption).foregroundColor(.secondary)
                if let err = validationError {
                    Text(err).foregroundColor(.red).font(.caption)
                }
            }
            if type == .windsurfEnterprise {
                SecureField("Windsurf Service Key", text: $windsurfServiceKey)
                TextField("Group Name (optional)", text: $windsurfGroupName)
                Text("Uses Windsurf enterprise analytics + team credit balance APIs.")
                    .font(.caption).foregroundColor(.secondary)
                if let err = validationError {
                    Text(err).foregroundColor(.red).font(.caption)
                }
            }
            if type == .githubCopilot {
                SecureField("GitHub Token", text: $githubToken)
                TextField("GitHub Organization", text: $githubOrganization)
                Text("Token needs org Copilot metrics access (`read:org` or `read:enterprise`).")
                    .font(.caption).foregroundColor(.secondary)
                if let err = validationError {
                    Text(err).foregroundColor(.red).font(.caption)
                }
            }
            if type == .claudeAI {
                SecureField("Session Token (from claude.ai cookie)", text: $sessionToken)
                Text("To get your session token: open claude.ai in browser → DevTools (⌥⌘I) → Application → Cookies → copy the value of 'sessionKey'.")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .disabled(name.isEmpty || !canSave)
            }
        }.padding().frame(width: 360)
    }

    private func save() {
        validationError = nil
        if type == .claudeAI {
            let a = Account(name: name, type: type)
            if !sessionToken.isEmpty {
                try? KeychainManager.store(key: sessionToken, service: AppConstants.keychainSessionTokenService, account: a.id.uuidString)
            }
            onSave(a, nil)
            dismiss()
            return
        }
        if type == .openAIOrg {
            validating = true
            Task {
                let client = OpenAIOrgUsageClient(adminAPIKey: openAIAdminKey)
                let valid = await client.validateAccess()
                await MainActor.run {
                    validating = false
                    if valid {
                        let payload = ProviderCredentialCodec.encodeOpenAI(OpenAIOrgCredentialPayload(adminKey: openAIAdminKey))
                        let a = Account(name: name, type: type)
                        onSave(a, payload)
                        dismiss()
                    } else {
                        validationError = "Invalid OpenAI admin key or insufficient org permissions"
                    }
                }
            }
            return
        }
        if type == .windsurfEnterprise {
            validating = true
            Task {
                let client = WindsurfEnterpriseClient(serviceKey: windsurfServiceKey, groupName: windsurfGroupName)
                let valid = await client.validateAccess()
                await MainActor.run {
                    validating = false
                    if valid {
                        let payload = ProviderCredentialCodec.encodeWindsurf(
                            WindsurfEnterpriseCredentialPayload(
                                serviceKey: windsurfServiceKey,
                                groupName: windsurfGroupName
                            )
                        )
                        let a = Account(name: name, type: type)
                        onSave(a, payload)
                        dismiss()
                    } else {
                        validationError = "Invalid Windsurf service key or group access"
                    }
                }
            }
            return
        }
        if type == .githubCopilot {
            validating = true
            Task {
                let client = GitHubCopilotMetricsClient(token: githubToken, organization: githubOrganization)
                let valid = await client.validateAccess()
                await MainActor.run {
                    validating = false
                    if valid {
                        let payload = ProviderCredentialCodec.encodeCopilot(
                            GitHubCopilotCredentialPayload(token: githubToken, organization: githubOrganization)
                        )
                        let a = Account(name: name, type: type)
                        onSave(a, payload)
                        dismiss()
                    } else {
                        validationError = "Invalid GitHub token/org, or Copilot metrics access not enabled"
                    }
                }
            }
            return
        }
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

    private var canSave: Bool {
        let capabilityMode = type.capabilities.credentialMode
        if capabilityMode == .none {
            return true
        }
        switch type {
        case .claudeCode, .codex, .gemini:
            return true
        case .anthropicAPI:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openAIOrg:
            return !openAIAdminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .windsurfEnterprise:
            return !windsurfServiceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .githubCopilot:
            return !githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .claudeAI:
            return !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    @State private var commandError: String?

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
                .onChange(of: shellCommand) { cmd in
                    commandError = AutomationEngine.validateCommand(cmd)
                }
            if let err = commandError {
                Text(err).foregroundColor(.red).font(.caption)
            }
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
                }.disabled(shellCommand.isEmpty || commandError != nil)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let d = Double(threshold), !name.isEmpty, !shellCommand.isEmpty, commandError == nil else { return }
                    let rule = AutomationRule(name: name, triggerType: triggerType, threshold: d, shellCommand: shellCommand)
                    onSave(rule)
                    dismiss()
                }.disabled(commandError != nil)
            }
        }.padding().frame(width: 380)
    }
}

// MARK: – Hotkey Tab

struct HotkeyTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var hasAccessibility = AXIsProcessTrusted()

    var body: some View {
        Form {
            Toggle("Enable global hotkey", isOn: $config.hotkey.enabled)
            if !hasAccessibility {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility access required for global hotkey.")
                        .foregroundColor(.orange).font(.caption)
                    Button("Grant Accessibility Access…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            if config.hotkey.enabled {
                TextField("Key", text: $config.hotkey.key)
                MultiPicker(label: "Modifiers", options: ["command","option","shift","control"], selection: $config.hotkey.modifiers)
                Divider()
                Section("Hotkey Recorder") {
                    HotkeyRecorderControl(config: $config.hotkeyConfig)
                }
            }
        }
        .onAppear { hasAccessibility = AXIsProcessTrusted() }
        .onChange(of: config.hotkey) { _ in
            ConfigManager.shared.save(config)
            HotkeyManager.shared.register(config: config.hotkey)
        }
        .onChange(of: config.hotkeyConfig) { _ in ConfigManager.shared.save(config) }
        .padding()
    }
}

// MARK: – Hotkey Recorder

struct HotkeyRecorderControl: View {
    @Binding var config: HotkeyConfig
    @State private var isRecording = false
    @State private var pendingKeyCode: Int?
    @State private var pendingModifiers: [String] = []
    @State private var monitor: Any?

    private var bindingLabel: String {
        let mods = config.primaryModifiers.map {
            switch $0 {
            case "command": return "⌘"
            case "shift": return "⇧"
            case "option": return "⌥"
            case "control": return "⌃"
            default: return $0
            }
        }.joined()
        let keyName = keyName(for: config.primaryKeyCode)
        return "\(mods)\(keyName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Binding:").foregroundColor(.secondary)
                Text(isRecording ? "Press a key…" : bindingLabel)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                Spacer()
                Button(isRecording ? "Cancel" : "Record") {
                    if isRecording { stopRecording() } else { startRecording() }
                }
                if isRecording, let kc = pendingKeyCode {
                    Button("Confirm") {
                        config.primaryKeyCode = kc
                        config.primaryModifiers = pendingModifiers
                        stopRecording()
                        ConfigManager.shared.save(ConfigManager.shared.load())
                    }
                }
            }
            Toggle("Chord enabled", isOn: $config.chordEnabled)
        }
    }

    private func startRecording() {
        isRecording = true
        pendingKeyCode = nil; pendingModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            pendingKeyCode = Int(event.keyCode)
            var mods: [String] = []
            if event.modifierFlags.contains(.command) { mods.append("command") }
            if event.modifierFlags.contains(.shift) { mods.append("shift") }
            if event.modifierFlags.contains(.option) { mods.append("option") }
            if event.modifierFlags.contains(.control) { mods.append("control") }
            pendingModifiers = mods
            return nil // consume event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func keyName(for keyCode: Int) -> String {
        let map: [Int: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
            11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",
            20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",
            29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",
            39:"'",40:"K",41:";",43:",",44:"/",45:"N",46:"M",47:".",49:"Space",
        ]
        return map[keyCode] ?? "?"
    }
}

struct MultiPicker: View {
    let label: String
    let options: [String]
    @Binding var selection: [String]
    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundColor(.secondary)
            HStack {
                ForEach(options, id: \.self) { opt in
                    Toggle(opt, isOn: Binding(
                        get: { selection.contains(opt) },
                        set: { v in if v { selection.append(opt) } else { selection.removeAll { $0 == opt } } }
                    )).toggleStyle(.checkbox)
                }
            }
        }
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
    @State private var isInstalling = false
    @State private var lastInstallError: String? = UserDefaults.standard.string(forKey: "lastCLIInstallError")

    private let snippet = "claude-usage"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLI Binary").font(.headline)
            Text("Install the claude-usage binary to access usage data from the terminal.")
            Button(isInstalling ? "Installing..." : "Install to /usr/local/bin") { installCLI() }
                .disabled(isInstalling)
            if let lastInstallError, !lastInstallError.isEmpty {
                Text(lastInstallError)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }

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
        guard let cliBinary = packagedCLIBinaryURL() else {
            let msg = "Bundled CLI binary not found in app bundle."
            lastInstallError = msg
            UserDefaults.standard.set(msg, forKey: "lastCLIInstallError")
            return
        }
        let dest = URL(fileURLWithPath: "/usr/local/bin/claude-usage")
        isInstalling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runInstallCommand(source: cliBinary, destination: dest)
            DispatchQueue.main.async {
                isInstalling = false
                if result.success {
                    lastInstallError = nil
                    UserDefaults.standard.removeObject(forKey: "lastCLIInstallError")
                } else {
                    let message = result.message ?? "CLI install failed."
                    lastInstallError = message
                    UserDefaults.standard.set(message, forKey: "lastCLIInstallError")
                }
            }
        }
    }

    private func packagedCLIBinaryURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("claude-usage"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/claude-usage"),
            Bundle.main.resourceURL?.appendingPathComponent("claude-usage"),
        ]
        return candidates
            .compactMap { $0 }
            .first(where: { fm.isExecutableFile(atPath: $0.path) })
    }

    private func runInstallCommand(source: URL, destination: URL) -> (success: Bool, message: String?) {
        let script = "cp '\(source.path)' '\(destination.path)' && chmod +x '\(destination.path)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return (false, "CLI install failed to start: \(error.localizedDescription)")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard task.terminationStatus == 0 else {
            if !output.isEmpty { return (false, output) }
            return (false, "CLI install failed with exit code \(task.terminationStatus).")
        }
        return (true, nil)
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
