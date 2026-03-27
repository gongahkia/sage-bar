import AppKit
import SwiftUI
import UserNotifications

final class OnboardingWindowController: NSWindowController {
  static let shared = OnboardingWindowController()

  private init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Set Up Sage Bar"
    window.toolbarStyle = .unifiedCompact
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
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
      SetupExperienceStore.shared.state.completionMode == nil
    {
      // swiftlint:disable:previous opening_brace
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
  private let contentCornerRadius: CGFloat = 24

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      wizardHeader

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          stepContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(contentBackground)
        }
        .padding(24)
      }

      Divider()
      actionBar
    }
    .frame(width: 720, height: 640)
    .background(
      LinearGradient(
        colors: [
          Color(nsColor: .windowBackgroundColor),
          // swiftlint:disable:next trailing_comma
          Color.accentColor.opacity(0.05),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
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

  @ViewBuilder
  private var stepContent: some View {
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

  private var wizardHeader: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Sage Bar Setup")
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundColor(.secondary)

          Text(stepTitle)
            .font(.system(size: 30, weight: .bold))

          Text(stepSubtitle)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 12)

        Text(stepProgressLabel)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color.white.opacity(0.65))
          .clipShape(Capsule())
      }

      ProgressView(value: stepProgressValue, total: 1)
        .tint(.accentColor)

      HStack(spacing: 8) {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          SetupStepChip(
            title: shortTitle(for: step),
            isCurrent: currentStep == step,
            isComplete: index < currentIndex
          )
        }
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 28)
    .padding(.bottom, 24)
    .background(
      LinearGradient(
        colors: [
          Color.accentColor.opacity(0.18),
          Color.accentColor.opacity(0.05),
          // swiftlint:disable:next trailing_comma
          Color.clear,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }

  private var actionBar: some View {
    HStack(spacing: 12) {
      if currentIndex > 0 {
        Button("Back") {
          validationError = nil
          validationSuccess = nil
          currentIndex -= 1
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      }

      Spacer()

      if currentStep == .finish {
        Button("Open Sage Bar") {
          onFinish()
          Task { @MainActor in
            MenuBarManager.shared.presentPopover()
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Button("Open Settings") {
          onFinish()
          SettingsWindowController.shared.showWindow()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        Button("Refresh now") {
          onFinish()
          Task { @MainActor in
            PollingService.shared.forceRefresh()
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      } else {
        Button(nextButtonTitle) {
          Task { await advance() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canAdvance || isValidating)
      }
    }
    .padding(24)
    .background(.ultraThinMaterial)
  }

  private var contentBackground: some View {
    RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
      .fill(Color(nsColor: .controlBackgroundColor))
      .overlay(
        RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.06), radius: 20, y: 10)
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

  private var stepProgressLabel: String {
    "Step \(min(currentIndex + 1, steps.count)) of \(steps.count)"
  }

  private var stepProgressValue: Double {
    guard !steps.isEmpty else { return 0 }
    return Double(min(currentIndex + 1, steps.count)) / Double(steps.count)
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
    VStack(alignment: .leading, spacing: 20) {
      Text("Start with one provider, then let Sage Bar keep the status item current for you.")
        .font(.headline)

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        SetupFeatureCard(
          title: "Track usage live",
          subtitle: "See cost, tokens, quota state, and freshness from the menu bar.",
          systemImage: "menubar.rectangle"
        )
        SetupFeatureCard(
          title: "Catch trends early",
          subtitle: "Forecast spend, burn rate, and quota health before they become surprises.",
          systemImage: "chart.line.uptrend.xyaxis"
        )
        SetupFeatureCard(
          title: "Work with local tools",
          subtitle: "Mix local agents and remote providers in one place with shared reporting.",
          systemImage: "person.2.fill"
        )
        SetupFeatureCard(
          title: "Stay lightweight",
          subtitle: "Finish setup now or keep the app in demo mode until you are ready.",
          systemImage: "sparkles"
        )
      }
    }
  }

  private var pathChoiceStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(SetupWizardPathChoice.allCases, id: \.self) { choice in
        Button {
          selectedPath = choice
          validationError = nil
          validationSuccess = nil
        } label: {
          SetupSelectionCard(
            title: choice.title,
            subtitle: choice.subtitle,
            systemImage: choice.systemImage,
            isSelected: selectedPath == choice
          )
        }
        .buttonStyle(.plain)
      }
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
          SetupSelectionCard(
            title: provider.displayName,
            subtitle: provider.providerStrategy == .core
              ? "No credential required" : "Requires credentials",
            systemImage: providerIcon(for: provider),
            isSelected: selectedProvider == provider
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var providerSetupStep: some View {
    VStack(alignment: .leading, spacing: 20) {
      setupSection(
        title: "Account Details",
        subtitle: "Choose how this source should appear in the menu bar, exports, and reporting."
      ) {
        TextField("Account name", text: $draft.name)
        TextField("Group label (optional)", text: $draft.groupLabel)
        Toggle("Pin account", isOn: $draft.isPinned)
      }

      if draft.type.supportsWorkstreamAttribution,
        let localStatus = draft.localSourceStatus
      {
        // swiftlint:disable:previous opening_brace
        SetupReadinessCard(
          title: localStatus.isAvailable ? "Source detected" : "Source missing",
          subtitle: LocalProviderLocator.hintText(for: draft.type),
          systemImage: localStatus.isAvailable
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
          accentColor: localStatus.isAvailable ? .green : .orange,
          pathText: localStatus.displayPath
        ) {
          EmptyView()
        }

        if !localStatus.isAvailable || localStatus.isUsingOverride {
          HStack(spacing: 10) {
            TextField("Manual override path", text: $draft.localDataPath)
            Button("Browse…") {
              if let path = LocalProviderLocator.browseForDirectory(
                initialPath: localStatus.displayPath
              ) {
                draft.localDataPath = path
              }
            }
          }
        }
      }

      if draft.type.providerStrategy != .core {
        setupSection(
          title: "Credentials",
          subtitle: "Provide the minimum access Sage Bar needs to validate and refresh this source."
        ) {
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
        }
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

  private var systemReadinessStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      readinessRow(
        title: "Notifications",
        subtitle: notificationSummary,
        buttonTitle: "Open Notifications Settings"
      ) {
        NotificationManager.shared.requestPermission()
        NSWorkspace.shared.open(
          URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
      }

      readinessRow(
        title: "Accessibility",
        subtitle: hasAccessibility
          ? "Granted for the global hotkey." : "Required for the global hotkey.",
        buttonTitle: "Open Accessibility Settings"
      ) {
        NSWorkspace.shared.open(
          URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
      }

      readinessRow(
        title: "Menu bar",
        subtitle: "Sage Bar lives in the top-right menu bar area and opens from its status item.",
        buttonTitle: "Open Sage Bar"
      ) {
        Task { @MainActor in
          MenuBarManager.shared.presentPopover()
        }
      }

      Spacer()
    }
    .task {
      await refreshPermissionStatuses()
    }
  }

  private func readinessRow(
    title: String, subtitle: String, buttonTitle: String, action: @escaping () -> Void
  ) -> some View {
    SetupReadinessCard(
      title: title,
      subtitle: subtitle,
      systemImage: readinessIcon(for: title),
      accentColor: readinessAccentColor(for: title)
    ) {
      Button(buttonTitle, action: action)
        .buttonStyle(.bordered)
    }
  }

  private var finishStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      if selectedPath == .connectAccount, let provisionedResult {
        SetupFeatureCard(
          title: "Validated account: \(provisionedResult.account.name)",
          subtitle: provisionedResult.account.type.displayName,
          systemImage: "checkmark.seal.fill"
        )
      } else if selectedPath == .demoMode {
        SetupFeatureCard(
          title: "Demo mode is enabled",
          subtitle: "Empty states now show a sample preview until you connect a real account.",
          systemImage: "sparkles"
        )
      } else {
        SetupFeatureCard(
          title: "Setup was skipped",
          subtitle:
            "Sage Bar will keep a lightweight finish-setup prompt until your first account is validated.",
          systemImage: "clock.arrow.circlepath"
        )
      }
      Spacer()
    }
  }

  private func shortTitle(for step: SetupWizardStep) -> String {
    switch step {
    case .welcome:
      return "Welcome"
    case .pathChoice:
      return "Path"
    case .providerPicker:
      return "Provider"
    case .providerSetup:
      return "Connect"
    case .systemReadiness:
      return "Readiness"
    case .finish:
      return "Finish"
    }
  }

  private func providerIcon(for provider: AccountType) -> String {
    switch provider {
    case .claudeCode:
      return "terminal"
    case .codex:
      return "chevron.left.forwardslash.chevron.right"
    case .gemini:
      return "sparkles"
    case .anthropicAPI:
      return "key.fill"
    case .openAIOrg:
      return "building.2.fill"
    case .windsurfEnterprise:
      return "wind"
    case .githubCopilot:
      return "person.badge.shield.checkmark"
    case .claudeAI:
      return "message.badge"
    }
  }

  private func readinessIcon(for title: String) -> String {
    switch title {
    case "Notifications":
      return "bell.badge"
    case "Accessibility":
      return "figure.wave"
    default:
      return "menubar.rectangle"
    }
  }

  private func readinessAccentColor(for title: String) -> Color {
    switch title {
    case "Notifications":
      return notificationAuthorization == .denied ? .orange : .accentColor
    case "Accessibility":
      return hasAccessibility ? .green : .orange
    default:
      return .accentColor
    }
  }

  private func setupSection<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)

      Text(subtitle)
        .font(.caption)
        .foregroundColor(.secondary)

      VStack(alignment: .leading, spacing: 10) {
        content()
      }
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

private struct SetupFeatureCard: View {
  let title: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundColor(.accentColor)

      Text(title)
        .font(.headline)

      Text(subtitle)
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.accentColor.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 1)
    )
  }
}

private struct SetupSelectionCard: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: systemImage)
        .font(.title3)
        .frame(width: 28)
        .foregroundColor(isSelected ? .accentColor : .secondary)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(subtitle)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(
          isSelected ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.06), lineWidth: 1)
    )
  }
}

private struct SetupReadinessCard<Accessory: View>: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let accentColor: Color
  var pathText: String?
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: systemImage)
          .foregroundColor(accentColor)
          .font(.title3)
          .frame(width: 26)

        VStack(alignment: .leading, spacing: 6) {
          Text(title)
            .font(.headline)
          Text(subtitle)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 12)
      }

      if let pathText {
        Text(pathText)
          .font(.caption2)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }

      accessory()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(accentColor.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(accentColor.opacity(0.16), lineWidth: 1)
    )
  }
}

private struct SetupStepChip: View {
  let title: String
  let isCurrent: Bool
  let isComplete: Bool

  var body: some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundColor(foregroundColor)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(backgroundColor)
      .clipShape(Capsule())
  }

  private var foregroundColor: Color {
    if isCurrent || isComplete {
      return .accentColor
    }
    return .secondary
  }

  private var backgroundColor: Color {
    if isCurrent {
      return Color.white.opacity(0.75)
    }
    if isComplete {
      return Color.accentColor.opacity(0.12)
    }
    return Color.white.opacity(0.45)
  }
}
