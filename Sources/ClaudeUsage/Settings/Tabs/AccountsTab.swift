import SwiftUI

// MARK: – Accounts Tab

struct AccountsTab: View {
    private let virtualizationThreshold = 40
    @State private var config = ConfigManager.shared.load()
    @State private var showAddSheet = false
    @State private var deleteTarget: Account?
    @State private var showDeleteAlert = false
    @State private var connectionStatus: [UUID: String] = [:]
    @State private var connectionTesting: Set<UUID> = []
    @State private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservedObject private var polling = PollingService.shared
    @ObservedObject private var setupExperience = SetupExperienceStore.shared

    private var displayedAccounts: [Account] {
        Account.sortedForDisplay(config.accounts)
    }

    private var hasClaudeAIAccount: Bool {
        config.accounts.contains(where: { $0.type == .claudeAI })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let setupCard = ProductStateResolver.setupCTA(config: config) {
                ProductStateCardView(card: setupCard) { action in
                    handleProductStateAction(action)
                }
                .padding()
                Divider()
            }
            if displayedAccounts.count > virtualizationThreshold {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(displayedAccounts) { account in
                            accountRowContent(account)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            } else {
                List {
                    ForEach(displayedAccounts) { account in
                        accountRowContent(account)
                    }
                    .onDelete(perform: deleteAccounts)
                }
            }
            HStack {
                Button("Run Setup Wizard") {
                    OnboardingWindowController.shared.showWindow(force: true)
                }
                .font(.caption)
                Button("Enable All") {
                    for index in config.accounts.indices {
                        config.accounts[index].isActive = true
                    }
                    ConfigManager.shared.save(config)
                }
                .font(.caption)
                Button("Disable All") {
                    for index in config.accounts.indices {
                        config.accounts[index].isActive = false
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
            }
            .padding()
            if hasClaudeAIAccount {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Claude AI Quota Alerts").font(.headline)
                    Toggle("Notify on low messages", isOn: Binding(
                        get: { config.claudeAI.notifyOnLowMessages },
                        set: { newValue in
                            config.claudeAI.notifyOnLowMessages = newValue
                            ConfigManager.shared.save(config)
                        }
                    ))
                    Stepper(
                        "Low-message threshold: \(config.claudeAI.lowMessagesThreshold)",
                        value: Binding(
                            get: { config.claudeAI.lowMessagesThreshold },
                            set: { newValue in
                                config.claudeAI.lowMessagesThreshold = max(1, newValue)
                                ConfigManager.shared.save(config)
                            }
                        ),
                        in: 1...100
                    )
                    .disabled(!config.claudeAI.notifyOnLowMessages)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet(showExperimentalProviders: config.display.showExperimentalProviders) { result in
                switch AccountProvisioningService.persist(result, config: &config) {
                case .success:
                    return nil
                case .failure(let error):
                    return error.message
                }
            }
        }
        .alert("Delete \"\(deleteTarget?.name ?? "")\"?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                guard let target = deleteTarget else { return }
                removeAccount(target)
                deleteTarget = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    @ViewBuilder
    private func accountRowContent(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.resolvedDisplayName(among: displayedAccounts)).fontWeight(.medium)
                    if let groupLabel = account.trimmedGroupLabel {
                        Text(groupLabel).font(.caption2).foregroundColor(.secondary)
                    }
                    Text(account.type.displayName).font(.caption).foregroundColor(.secondary)
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
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    deleteTarget = account
                    showDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                Toggle("", isOn: Binding(
                    get: { account.isActive },
                    set: { newValue in
                        updateAccount(account.id) { $0.isActive = newValue }
                    }
                ))
                .labelsHidden()
            }
            if let status = connectionStatus[account.id] {
                Text(status)
                    .font(.caption2)
                    .foregroundColor(status.hasPrefix("✓") ? .green : .red)
                    .padding(.leading, 4)
            }
            if account.type.supportsWorkstreamAttribution,
               let localStatus = LocalProviderLocator.status(for: account) {
                Text(localStatus.isAvailable ? "Source: \(localStatus.displayPath)" : "Missing source: \(localStatus.displayPath)")
                    .font(.caption2)
                    .foregroundColor(localStatus.isAvailable ? .secondary : .orange)
                    .padding(.leading, 4)
            }
            if let health = polling.providerHealthScore(for: account.id) {
                Text("Provider health: \(Int((health * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundColor(health >= 0.8 ? .green : (health >= 0.5 ? .orange : .red))
                    .padding(.leading, 4)
            }
            HStack {
                Toggle("Pinned", isOn: Binding(
                    get: { account.isPinned },
                    set: { newValue in
                        updateAccount(account.id) { $0.isPinned = newValue }
                    }
                ))
                .font(.caption)
                TextField("Group label", text: Binding(
                    get: { account.groupLabel ?? "" },
                    set: { newValue in
                        updateAccount(account.id) { draft in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.groupLabel = trimmed.isEmpty ? nil : trimmed
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }
            if account.type.supportsWorkstreamAttribution {
                HStack {
                    TextField("Local data path override", text: Binding(
                        get: { account.localDataPath ?? "" },
                        set: { newValue in
                            updateAccount(account.id) { draft in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                draft.localDataPath = trimmed.isEmpty ? nil : trimmed
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    Button("Browse…") {
                        if let path = LocalProviderLocator.browseForDirectory(initialPath: account.localDataPath) {
                            updateAccount(account.id) { $0.localDataPath = path }
                        }
                    }
                    .font(.caption)
                }
            }
            if let index = config.accounts.firstIndex(where: { $0.id == account.id }) {
                Stepper(
                    "Order: \(config.accounts[index].order)",
                    value: Binding(
                        get: { config.accounts[index].order },
                        set: { newValue in
                            updateAccount(account.id) { $0.order = newValue }
                        }
                    ),
                    in: -100...100
                )
                .font(.caption)

                if account.type.supportsWorkstreamAttribution {
                    DisclosureGroup("Workstream Attribution") {
                        Text("Match local session file paths to a named workstream. Leave this empty to use automatic path inference.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if config.accounts[index].workstreamRules.isEmpty {
                            Text("No rules yet. Automatic inference will use the provider's session path structure.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        ForEach(Array(config.accounts[index].workstreamRules.enumerated()), id: \.element.id) { offset, rule in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    TextField("Workstream name", text: Binding(
                                        get: { config.accounts[index].workstreamRules[offset].name },
                                        set: { newValue in
                                            updateAccount(account.id) { draft in
                                                guard draft.workstreamRules.indices.contains(offset) else { return }
                                                draft.workstreamRules[offset].name = newValue
                                            }
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    Button(role: .destructive) {
                                        updateAccount(account.id) { draft in
                                            guard draft.workstreamRules.indices.contains(offset) else { return }
                                            draft.workstreamRules.remove(at: offset)
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                TextField("Path contains", text: Binding(
                                    get: { config.accounts[index].workstreamRules[offset].pathPattern },
                                    set: { newValue in
                                        updateAccount(account.id) { draft in
                                            guard draft.workstreamRules.indices.contains(offset) else { return }
                                            draft.workstreamRules[offset].pathPattern = newValue
                                        }
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                            .padding(.vertical, 2)
                        }
                        Button("+ Workstream Rule") {
                            updateAccount(account.id) { draft in
                                draft.workstreamRules.append(
                                    WorkstreamRule(name: "New Workstream", pathPattern: "")
                                )
                            }
                        }
                        .font(.caption)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func updateAccount(_ accountID: UUID, mutate: (inout Account) -> Void) {
        guard let index = config.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        mutate(&config.accounts[index])
        ConfigManager.shared.save(config)
    }

    private func deleteAccounts(_ offsets: IndexSet) {
        let targets = offsets.map { displayedAccounts[$0] }
        for target in targets {
            removeAccount(target)
        }
    }

    private func removeAccount(_ account: Account) {
        do {
            try KeychainManager.delete(service: AppConstants.keychainService, account: account.id.uuidString)
        } catch {
            ErrorLogger.shared.log("Keychain delete failed for \(account.name): \(error.localizedDescription)", level: "WARN")
        }
        if account.type == .claudeAI {
            do {
                try KeychainManager.delete(service: AppConstants.keychainSessionTokenService, account: account.id.uuidString)
            } catch {
                ErrorLogger.shared.log("Keychain session delete failed for \(account.name): \(error.localizedDescription)", level: "WARN")
            }
            Task {
                await ClaudeAIStatusStore.shared.remove(accountId: account.id)
                await ClaudeAIQuotaHistoryStore.shared.remove(accountId: account.id)
            }
        }
        config.accounts.removeAll { $0.id == account.id }
        ConfigManager.shared.save(config)
    }

    private func testConnection(account: Account) async -> String {
        guard account.type.capabilities.supportsConnectionTest else {
            return "✗ Test connection unsupported for this provider type"
        }
        return await AccountProvisioningService.testConnection(account: account)
    }

    private func handleProductStateAction(_ action: ProductStateActionKind) {
        switch action {
        case .runSetupWizard:
            OnboardingWindowController.shared.showWindow(force: true)
        case .disableDemoMode:
            SetupExperienceStore.shared.disableDemoMode()
        case .openSettings, .openAccountsSettings, .reconnectSettings, .refreshNow, .resetDateRange, .exportAllTime:
            break
        }
        config = ConfigManager.shared.load()
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
    var onSave: (AccountProvisioningResult) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = AccountSetupDraft(name: "Claude Code", type: .claudeCode)
    @State private var validating = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account").font(.headline)
            TextField("Name", text: $draft.name)
            TextField("Group Label (optional)", text: $draft.groupLabel)
            Toggle("Pin account", isOn: $draft.isPinned)
            Picker("Type", selection: $draft.type) {
                ForEach(providerOptions, id: \.self) { providerType in
                    Text(providerType.displayName).tag(providerType)
                }
            }
            if draft.type.supportsWorkstreamAttribution,
               let localStatus = draft.localSourceStatus {
                Text(localStatus.isAvailable ? "Detected: \(localStatus.displayPath)" : "Missing: \(localStatus.displayPath)")
                    .font(.caption)
                    .foregroundColor(localStatus.isAvailable ? .secondary : .orange)
                if !localStatus.isAvailable || localStatus.isUsingOverride {
                    HStack {
                        TextField("Manual override path", text: $draft.localDataPath)
                        Button("Browse…") {
                            if let path = LocalProviderLocator.browseForDirectory(initialPath: localStatus.displayPath) {
                                draft.localDataPath = path
                            }
                        }
                    }
                }
            }
            if draft.type == .anthropicAPI {
                SecureField("API Key", text: $draft.apiKey)
            }
            if draft.type == .openAIOrg {
                SecureField("OpenAI Admin Key", text: $draft.openAIAdminKey)
                Text("Requires an OpenAI admin key with organization usage/cost API access.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if draft.type == .windsurfEnterprise {
                SecureField("Windsurf Service Key", text: $draft.windsurfServiceKey)
                TextField("Group Name (optional)", text: $draft.windsurfGroupName)
                Text("Uses Windsurf enterprise analytics + team credit balance APIs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if draft.type == .githubCopilot {
                SecureField("GitHub Token", text: $draft.githubToken)
                TextField("GitHub Organization", text: $draft.githubOrganization)
                Text("Token needs org Copilot metrics access (`read:org` or `read:enterprise`).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let validationError {
                    Text(validationError).foregroundColor(.red).font(.caption)
                }
            }
            if draft.type == .claudeAI {
                SecureField("Session Token (from claude.ai cookie)", text: $draft.sessionToken)
                Text("To get your session token: open claude.ai in browser → DevTools (⌥⌘I) → Application → Cookies → copy the value of 'sessionKey'.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let validationError {
                Text(validationError)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .disabled(!AccountProvisioningService.canSave(draft) || validating)
            }
        }
        .padding()
        .frame(width: 380)
        .onChange(of: draft.type) { newValue in
            let defaultNames = AccountType.allCases.map(AccountProvisioningService.defaultName(for:))
            if draft.trimmedName.isEmpty || defaultNames.contains(draft.name) {
                draft.name = AccountProvisioningService.defaultName(for: newValue)
            }
            draft.localDataPath = ""
            validationError = nil
        }
    }

    private var providerOptions: [AccountType] {
        showExperimentalProviders ? AccountType.allCases : AccountType.allCases.filter(\.isCoreProvider)
    }

    private func save() {
        validationError = nil
        validating = true
        Task {
            let result = await AccountProvisioningService.provision(draft)
            await MainActor.run {
                validating = false
                switch result {
                case .success(let provisioned):
                    if let error = onSave(provisioned) {
                        validationError = error
                    } else {
                        dismiss()
                    }
                case .failure(let error):
                    validationError = error.message
                }
            }
        }
    }
}
