import AppKit
import SwiftUI
import UserNotifications

final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Sage Bar"
        window.center()
        super.init(window: window)
        window.delegate = self
        updateRootView()
    }

    required init?(coder: NSCoder) { nil }

    func showWindow(force: Bool = false) {
        let config = ConfigManager.shared.load()
        guard force || SetupExperienceStore.shared.shouldPresentWizard(config: config) else { return }
        updateRootView()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func updateRootView() {
        window?.contentView = NSHostingView(
            rootView: SetupWizardView {
                self.window?.close()
            }
        )
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        let config = ConfigManager.shared.load()
        if !SetupExperienceStore.shared.hasValidatedAccount(config: config),
           SetupExperienceStore.shared.state.completionMode == nil {
            SetupExperienceStore.shared.markCompleted(.skipped)
        }
        NSApp.setActivationPolicy(.accessory)
    }
}

private enum SetupWizardPathChoice: String, CaseIterable {
    case connectAccount
    case demoMode
    case setUpLater

    var title: String {
        switch self {
        case .connectAccount:
            return "Connect an account"
        case .demoMode:
            return "Try demo mode"
        case .setUpLater:
            return "Set up later"
        }
    }

    var subtitle: String {
        switch self {
        case .connectAccount:
            return "Validate a provider now and start seeing real usage."
        case .demoMode:
            return "Preview Sage Bar with sample guidance and empty-state content."
        case .setUpLater:
            return "Skip account setup for now and finish it from Settings later."
        }
    }

    var systemImage: String {
        switch self {
        case .connectAccount:
            return "link.badge.plus"
        case .demoMode:
            return "sparkles"
        case .setUpLater:
            return "clock.arrow.circlepath"
        }
    }
}

private enum SetupWizardStep: Hashable {
    case welcome
    case pathChoice
    case providerPicker
    case providerSetup
    case systemReadiness
    case finish
}

private struct SetupWizardView: View {
    let onFinish: () -> Void

    @State private var selectedPath: SetupWizardPathChoice?
    @State private var selectedProvider: AccountType?
    @State private var draft = AccountSetupDraft()
    @State private var currentIndex = 0
    @State private var validationError: String?
    @State private var validationSuccess: String?
    @State private var isValidating = false
    @State private var provisionedResult: AccountProvisioningResult?
    @State private var didFinalize = false
    @State private var notificationAuthorization: UNAuthorizationStatus?
    @State private var hasAccessibility = AXIsProcessTrusted()

    private let showExperimentalProviders = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(stepTitle)
                    .font(.title)
                    .fontWeight(.bold)
                Text(stepSubtitle)
                    .foregroundColor(.secondary)
            }
            .padding(24)

            Divider()

            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .pathChoice:
                    pathChoiceStep
                case .providerPicker:
                    providerPickerStep
                case .providerSetup:
                    providerSetupStep
                case .systemReadiness:
                    systemReadinessStep
                case .finish:
                    finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()

            HStack {
                if currentIndex > 0 {
                    Button("Back") {
                        validationError = nil
                        validationSuccess = nil
                        currentIndex -= 1
                    }
                }

                Spacer()

                if currentStep == .finish {
                    Button("Open Sage Bar") {
                        onFinish()
                        MenuBarManager.shared.presentPopover()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open Settings") {
                        onFinish()
                        SettingsWindowController.shared.showWindow()
                    }
                    .buttonStyle(.bordered)

                    Button("Refresh now") {
                        onFinish()
                        PollingService.shared.forceRefresh()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(nextButtonTitle) {
                        Task { await advance() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance || isValidating)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 560)
        .task {
            await refreshPermissionStatuses()
        }
        .onAppear {
            draft.name = AccountProvisioningService.defaultName(for: draft.type)
        }
        .onChange(of: selectedProvider) { newValue in
            guard let newValue else { return }
            draft.type = newValue
            let defaultNames = AccountType.allCases.map(AccountProvisioningService.defaultName(for:))
            if draft.trimmedName.isEmpty || defaultNames.contains(draft.name) {
                draft.name = AccountProvisioningService.defaultName(for: newValue)
            }
            draft.localDataPath = ""
            validationError = nil
            validationSuccess = nil
            provisionedResult = nil
        }
        .onChange(of: currentStep) { step in
            if step == .finish {
                finalizeIfNeeded()
            }
        }
    }

    private var steps: [SetupWizardStep] {
        switch selectedPath {
        case .connectAccount:
            return [.welcome, .pathChoice, .providerPicker, .providerSetup, .systemReadiness, .finish]
        case .demoMode, .setUpLater:
            return [.welcome, .pathChoice, .systemReadiness, .finish]
        case nil:
            return [.welcome, .pathChoice]
        }
    }

    private var currentStep: SetupWizardStep {
        steps[min(currentIndex, max(0, steps.count - 1))]
    }

    private var stepTitle: String {
        switch currentStep {
        case .welcome:
            return "Welcome to Sage Bar"
        case .pathChoice:
            return "Choose your setup path"
        case .providerPicker:
            return "Pick your first provider"
        case .providerSetup:
            return "Connect \(draft.type.displayName)"
        case .systemReadiness:
            return "System readiness"
        case .finish:
            return "You're ready"
        }
    }

    private var stepSubtitle: String {
        switch currentStep {
        case .welcome:
            return "Track AI usage, limits, and spend from your macOS menu bar."
        case .pathChoice:
            return "The fastest path is to validate one account now."
        case .providerPicker:
            return "Choose a local source or connected provider."
        case .providerSetup:
            return "Validate this source now so Sage Bar can trust the account."
        case .systemReadiness:
            return "Confirm notifications, Accessibility, and where Sage Bar lives on macOS."
        case .finish:
            return finishSummary
        }
    }

    private var nextButtonTitle: String {
        switch currentStep {
        case .providerSetup:
            return isValidating ? "Validating…" : "Validate & Continue"
        default:
            return "Continue"
        }
    }

    private var canAdvance: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .pathChoice:
            return selectedPath != nil
        case .providerPicker:
            return selectedProvider != nil
        case .providerSetup:
            return AccountProvisioningService.canSave(draft)
        case .systemReadiness:
            return true
        case .finish:
            return true
        }
    }

    private var finishSummary: String {
        switch selectedPath {
        case .connectAccount:
            return "Your first account is validated and ready for polling."
        case .demoMode:
            return "Demo mode is active until you connect a real account."
        case .setUpLater:
            return "You can finish setup any time from Settings or the menu bar."
        case nil:
            return "Setup is ready."
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Menu bar usage tracking", systemImage: "menubar.rectangle")
            Label("Forecasts, alerts, and exports", systemImage: "chart.line.uptrend.xyaxis")
            Label("Local agents and connected providers", systemImage: "person.2.fill")
            Spacer()
        }
        .font(.title3)
    }

    private var pathChoiceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SetupWizardPathChoice.allCases, id: \.self) { choice in
                Button {
                    selectedPath = choice
                    validationError = nil
                    validationSuccess = nil
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: choice.systemImage)
                            .font(.title2)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.title).fontWeight(.semibold)
                            Text(choice.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selectedPath == choice ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var providerPickerStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            providerSection(title: "Local", providers: [.claudeCode, .codex, .gemini])
            providerSection(title: "Connected", providers: connectedProviders)
            Spacer()
        }
    }

    private func providerSection(title: String, providers: [AccountType]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(providers, id: \.self) { provider in
                Button {
                    selectedProvider = provider
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .fontWeight(.medium)
                            Text(provider.providerStrategy == .core ? "No credential required" : "Requires credentials")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if selectedProvider == provider {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedProvider == provider ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var providerSetupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Account name", text: $draft.name)
                TextField("Group label (optional)", text: $draft.groupLabel)
                Toggle("Pin account", isOn: $draft.isPinned)

                if draft.type.supportsWorkstreamAttribution,
                   let localStatus = draft.localSourceStatus {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(localStatus.isAvailable ? "Source detected" : "Source missing", systemImage: localStatus.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(localStatus.isAvailable ? .green : .orange)
                        Text(localStatus.displayPath)
                            .font(.caption)
                            .textSelection(.enabled)
                        Text(LocalProviderLocator.hintText(for: draft.type))
                            .font(.caption2)
                            .foregroundColor(.secondary)
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
                }

                switch draft.type {
                case .anthropicAPI:
                    SecureField("API key", text: $draft.apiKey)
                case .openAIOrg:
                    SecureField("OpenAI admin key", text: $draft.openAIAdminKey)
                    Text("Requires organization usage and cost API access.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .windsurfEnterprise:
                    SecureField("Windsurf service key", text: $draft.windsurfServiceKey)
                    TextField("Group name (optional)", text: $draft.windsurfGroupName)
                case .githubCopilot:
                    SecureField("GitHub token", text: $draft.githubToken)
                    TextField("GitHub organization", text: $draft.githubOrganization)
                case .claudeAI:
                    SecureField("Session token", text: $draft.sessionToken)
                    Text("Copy the `sessionKey` cookie value from claude.ai.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .claudeCode, .codex, .gemini:
                    EmptyView()
                }

                if let validationSuccess {
                    Text(validationSuccess)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var systemReadinessStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            readinessRow(
                title: "Notifications",
                subtitle: notificationSummary,
                buttonTitle: "Open Notifications Settings"
            ) {
                NotificationManager.shared.requestPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
            }

            readinessRow(
                title: "Accessibility",
                subtitle: hasAccessibility ? "Granted for the global hotkey." : "Required for the global hotkey.",
                buttonTitle: "Open Accessibility Settings"
            ) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            readinessRow(
                title: "Menu bar",
                subtitle: "Sage Bar lives in the top-right menu bar area and opens from its status item.",
                buttonTitle: "Open Sage Bar"
            ) {
                MenuBarManager.shared.presentPopover()
            }

            Spacer()
        }
        .task {
            await refreshPermissionStatuses()
        }
    }

    private func readinessRow(title: String, subtitle: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if selectedPath == .connectAccount, let provisionedResult {
                Text("Validated account: \(provisionedResult.account.name)")
                    .font(.headline)
                Text(provisionedResult.account.type.displayName)
                    .foregroundColor(.secondary)
            } else if selectedPath == .demoMode {
                Text("Demo mode is enabled.")
                    .font(.headline)
                Text("Empty states now show a sample preview until you connect a real account.")
                    .foregroundColor(.secondary)
            } else {
                Text("Setup was skipped.")
                    .font(.headline)
                Text("Sage Bar will keep a lightweight finish-setup prompt until your first account is validated.")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var notificationSummary: String {
        switch notificationAuthorization {
        case .some(.authorized), .some(.provisional), .some(.ephemeral):
            return "Granted for alerts and quota notifications."
        case .some(.denied):
            return "Denied. Open System Settings to allow notifications."
        case .some(.notDetermined):
            return "Not requested yet."
        case nil:
            return "Unavailable in an unbundled development run."
        @unknown default:
            return "Unknown notification state."
        }
    }

    private var connectedProviders: [AccountType] {
        let providers = AccountType.allCases.filter { !$0.isCoreProvider }
        return showExperimentalProviders ? providers : []
    }

    private func advance() async {
        validationError = nil
        validationSuccess = nil

        switch currentStep {
        case .providerSetup:
            isValidating = true
            let result = await AccountProvisioningService.provision(draft)
            isValidating = false
            switch result {
            case .success(let provisioned):
                provisionedResult = provisioned
                validationSuccess = "Validated \(provisioned.account.type.displayName)."
                currentIndex += 1
            case .failure(let error):
                validationError = error.message
            }
        default:
            if currentIndex < steps.count - 1 {
                currentIndex += 1
            }
        }
    }

    private func finalizeIfNeeded() {
        guard !didFinalize else { return }

        switch selectedPath {
        case .connectAccount:
            guard let provisionedResult else { return }
            var config = ConfigManager.shared.load()
            switch AccountProvisioningService.persist(provisionedResult, config: &config) {
            case .success:
                didFinalize = true
                validationSuccess = "Saved and validated."
            case .failure(let error):
                validationError = error.message
            }
        case .demoMode:
            didFinalize = true
            SetupExperienceStore.shared.enableDemoMode()
        case .setUpLater:
            didFinalize = true
            SetupExperienceStore.shared.markCompleted(.skipped)
        case nil:
            break
        }
    }

    private func refreshPermissionStatuses() async {
        notificationAuthorization = await NotificationManager.shared.authorizationStatus()
        hasAccessibility = AXIsProcessTrusted()
    }
}
