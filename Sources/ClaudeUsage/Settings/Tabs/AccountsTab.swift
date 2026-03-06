import SwiftUI

// MARK: – Accounts Tab

struct AccountsTab: View {
    private let virtualizationThreshold = 40
    @State private var config = ConfigManager.shared.load()
    @State private var showAddSheet = false
    @State private var deleteTarget: Account?
    @State private var connectionStatus: [UUID: String] = [:] // task 88
    @State private var connectionTesting: Set<UUID> = []
    @State private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservedObject private var polling = PollingService.shared

    var body: some View {
        VStack(alignment: .leading) {
            if config.accounts.count > virtualizationThreshold {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(config.accounts) { account in
                            accountRowContent(account)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            } else {
                List {
                    ForEach(config.accounts) { account in
                        accountRowContent(account)
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
            }
            HStack {
                Button("Enable All") {
                    for i in config.accounts.indices {
                        config.accounts[i].isActive = true
                    }
                    ConfigManager.shared.save(config)
                }
                .font(.caption)
                Button("Disable All") {
                    for i in config.accounts.indices {
                        config.accounts[i].isActive = false
                    }
                    ConfigManager.shared.save(config)
                }
                .font(.caption)
                Toggle("Experimental Providers", isOn: Binding(
                    get: { config.display.showExperimentalProviders },
                    set: { newValue in
                        config.display.showExperimentalProviders = newValue
                        ConfigManager.shared.save(config)
                    }
                ))
                .font(.caption)
                Spacer()
                Button("+") { showAddSheet = true }
            }.padding(.horizontal)
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet(showExperimentalProviders: config.display.showExperimentalProviders) { newAccount, key in
                config.accounts.append(newAccount)
                if let key, !key.isEmpty {
                    try? KeychainManager.store(key: key, service: AppConstants.keychainService, account: newAccount.id.uuidString)
                }
                ConfigManager.shared.save(config)
            }
        }
    }

    @ViewBuilder
    private func accountRowContent(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).fontWeight(.medium)
                    Text(account.type.rawValue).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if connectionTesting.contains(account.id) {
                    Button("Cancel") {
                        connectionTasks[account.id]?.cancel()
                        connectionTasks.removeValue(forKey: account.id)
                        connectionTesting.remove(account.id)
                        connectionStatus[account.id] = "✗ Cancelled"
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                } else {
                    Button("Test") {
                        connectionTesting.insert(account.id)
                        connectionStatus.removeValue(forKey: account.id)
                        let task = Task {
                            let result = await withTimeout(seconds: 10) {
                                await testConnection(account: account)
                            } ?? "✗ Timed out after 10s"
                            guard !Task.isCancelled else { return }
                            connectionStatus[account.id] = result
                            connectionTesting.remove(account.id)
                            connectionTasks.removeValue(forKey: account.id)
                        }
                        connectionTasks[account.id] = task
                    }.font(.caption).buttonStyle(.bordered)
                }
                Button(role: .destructive) { deleteTarget = account } label: {
                    Image(systemName: "trash")
                }.font(.caption).buttonStyle(.bordered)
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
            if let status = connectionStatus[account.id] {
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

    private func withTimeout<T>(seconds: Double, operation: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

struct AddAccountSheet: View {
    var showExperimentalProviders: Bool
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
                ForEach(providerOptions, id: \.self) { t in
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

    private var providerOptions: [AccountType] {
        showExperimentalProviders
            ? AccountType.allCases
            : AccountType.allCases.filter(\.isCoreProvider)
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

