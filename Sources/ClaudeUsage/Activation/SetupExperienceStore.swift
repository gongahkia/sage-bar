import Combine
import Foundation

enum SetupCompletionMode: String, Codable, Equatable {
    case validatedAccount
    case demoMode
    case skipped
}

struct SetupExperienceState: Codable, Equatable {
    var version: Int
    var completionMode: SetupCompletionMode?
    var completedAt: Date?
    var demoModeEnabled: Bool

    static var `default`: SetupExperienceState {
        SetupExperienceState(version: 1, completionMode: nil, completedAt: nil, demoModeEnabled: false)
    }
}

final class SetupExperienceStore: ObservableObject {
    static let shared = SetupExperienceStore()

    @Published private(set) var state: SetupExperienceState

    private let defaults: UserDefaults
    private let stateKey: String
    private let currentVersion: Int
    private let accountValidator: (Account) -> Bool

    init(
        defaults: UserDefaults = .standard,
        stateKey: String = "setupExperienceState",
        currentVersion: Int = 1,
        accountValidator: ((Account) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.stateKey = stateKey
        self.currentVersion = currentVersion
        self.accountValidator = accountValidator ?? Self.defaultAccountValidator
        self.state = Self.loadState(defaults: defaults, key: stateKey)
    }

    func shouldPresentWizard(config: Config = ConfigManager.shared.load()) -> Bool {
        if state.version < currentVersion {
            return true
        }
        return state.completionMode == nil && !hasValidatedAccount(config: config)
    }

    func shouldShowFinishSetupCTA(config: Config = ConfigManager.shared.load()) -> Bool {
        !hasValidatedAccount(config: config)
    }

    func markCompleted(_ mode: SetupCompletionMode) {
        state.version = currentVersion
        state.completionMode = mode
        state.completedAt = Date()
        if mode != .demoMode {
            state.demoModeEnabled = false
        }
        persist()
    }

    func enableDemoMode() {
        state.version = currentVersion
        state.completionMode = .demoMode
        state.completedAt = Date()
        state.demoModeEnabled = true
        persist()
    }

    func disableDemoMode() {
        state.demoModeEnabled = false
        if state.completionMode == .demoMode {
            state.completionMode = .skipped
        }
        persist()
    }

    func refresh() {
        state = Self.loadState(defaults: defaults, key: stateKey)
    }

    func hasValidatedAccount(config: Config = ConfigManager.shared.load()) -> Bool {
        for account in Account.activeAccounts(in: config) {
            if accountValidator(account) {
                return true
            }
        }
        return state.completionMode == .validatedAccount
    }

    private func persist() {
        do {
            let encoded = try JSONEncoder().encode(state)
            defaults.set(encoded, forKey: stateKey)
        } catch {
            ErrorLogger.shared.log("Failed to persist setup experience state: \(error.localizedDescription)", level: "WARN")
        }
    }

    private static func loadState(defaults: UserDefaults, key: String) -> SetupExperienceState {
        guard let data = defaults.data(forKey: key) else { return .default }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(SetupExperienceState.self, from: data)
        } catch {
            ErrorLogger.shared.log(
                "Failed to decode setup experience state; using defaults: \(error.localizedDescription)",
                level: "WARN"
            )
            return .default
        }
    }

    private static func defaultAccountValidator(account: Account) -> Bool {
        if account.type.supportsWorkstreamAttribution {
            return LocalProviderLocator.status(for: account)?.isAvailable == true
        }
        return hasStoredCredential(for: account)
    }

    private static func hasStoredCredential(for account: Account) -> Bool {
        let service: String
        switch account.type {
        case .claudeAI:
            service = AppConstants.keychainSessionTokenService
        case .anthropicAPI, .openAIOrg, .windsurfEnterprise, .githubCopilot:
            service = AppConstants.keychainService
        case .claudeCode, .codex, .gemini:
            return false
        }

        do {
            let value = try KeychainManager.retrieve(service: service, account: account.id.uuidString)
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }
}
