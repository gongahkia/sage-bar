import Foundation

struct AccountProvisioningError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct AccountSetupDraft: Equatable {
    var name: String = ""
    var type: AccountType = .claudeCode
    var groupLabel: String = ""
    var localDataPath: String = ""
    var isPinned: Bool = false
    var apiKey: String = ""
    var sessionToken: String = ""
    var openAIAdminKey: String = ""
    var windsurfServiceKey: String = ""
    var windsurfGroupName: String = ""
    var githubToken: String = ""
    var githubOrganization: String = ""

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var localSourceStatus: LocalProviderSourceStatus? {
        LocalProviderLocator.status(for: type, overridePath: localDataPath)
    }
}

struct AccountProvisioningResult {
    let account: Account
    let credentialService: String?
    let credentialValue: String?
}

enum AccountProvisioningService {
    static func canSave(_ draft: AccountSetupDraft) -> Bool {
        guard !draft.trimmedName.isEmpty else { return false }
        switch draft.type {
        case .claudeCode, .codex, .gemini:
            return draft.localSourceStatus?.isAvailable == true
        case .anthropicAPI:
            return !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openAIOrg:
            return !draft.openAIAdminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .windsurfEnterprise:
            return !draft.windsurfServiceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .githubCopilot:
            return !draft.githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !draft.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .claudeAI:
            return !draft.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func defaultName(for type: AccountType) -> String {
        switch type {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini"
        case .anthropicAPI:
            return "Anthropic API"
        case .openAIOrg:
            return "OpenAI Org"
        case .windsurfEnterprise:
            return "Windsurf"
        case .githubCopilot:
            return "GitHub Copilot"
        case .claudeAI:
            return "Claude AI"
        }
    }

    static func provision(_ draft: AccountSetupDraft) async -> Result<AccountProvisioningResult, AccountProvisioningError> {
        let account = Account(
            name: draft.trimmedName,
            type: draft.type,
            groupLabel: draft.groupLabel,
            localDataPath: draft.localDataPath,
            isPinned: draft.isPinned
        )

        switch draft.type {
        case .claudeCode, .codex, .gemini:
            guard let status = draft.localSourceStatus else {
                return .failure(AccountProvisioningError(message: "Unsupported local provider"))
            }
            guard status.isAvailable else {
                return .failure(AccountProvisioningError(message: "Directory not found at \(status.displayPath)"))
            }
            return .success(AccountProvisioningResult(account: account, credentialService: nil, credentialValue: nil))
        case .anthropicAPI:
            let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = await AnthropicAPIClient(apiKey: apiKey).validateKey()
            guard valid else { return .failure(AccountProvisioningError(message: "Invalid API key")) }
            return .success(AccountProvisioningResult(account: account, credentialService: AppConstants.keychainService, credentialValue: apiKey))
        case .openAIOrg:
            let adminKey = draft.openAIAdminKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = await OpenAIOrgUsageClient(adminAPIKey: adminKey).validateAccess()
            guard valid else { return .failure(AccountProvisioningError(message: "Invalid OpenAI admin key or insufficient org permissions")) }
            let payload = ProviderCredentialCodec.encodeOpenAI(OpenAIOrgCredentialPayload(adminKey: adminKey))
            return .success(AccountProvisioningResult(account: account, credentialService: AppConstants.keychainService, credentialValue: payload))
        case .windsurfEnterprise:
            let serviceKey = draft.windsurfServiceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let groupName = draft.windsurfGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = await WindsurfEnterpriseClient(serviceKey: serviceKey, groupName: groupName).validateAccess()
            guard valid else { return .failure(AccountProvisioningError(message: "Invalid Windsurf service key or inaccessible group")) }
            let payload = ProviderCredentialCodec.encodeWindsurf(
                WindsurfEnterpriseCredentialPayload(serviceKey: serviceKey, groupName: groupName)
            )
            return .success(AccountProvisioningResult(account: account, credentialService: AppConstants.keychainService, credentialValue: payload))
        case .githubCopilot:
            let token = draft.githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let organization = draft.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = await GitHubCopilotMetricsClient(token: token, organization: organization).validateAccess()
            guard valid else { return .failure(AccountProvisioningError(message: "Invalid GitHub token, organization, or Copilot metrics access")) }
            let payload = ProviderCredentialCodec.encodeCopilot(
                GitHubCopilotCredentialPayload(token: token, organization: organization)
            )
            return .success(AccountProvisioningResult(account: account, credentialService: AppConstants.keychainService, credentialValue: payload))
        case .claudeAI:
            let token = draft.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = await ClaudeAIClient(sessionToken: token).fetchUsage() != nil
            guard valid else { return .failure(AccountProvisioningError(message: "Invalid session token or claude.ai session expired")) }
            return .success(AccountProvisioningResult(account: account, credentialService: AppConstants.keychainSessionTokenService, credentialValue: token))
        }
    }

    @discardableResult
    static func persist(_ result: AccountProvisioningResult, config: inout Config) -> Result<Void, AccountProvisioningError> {
        config.accounts.append(result.account)
        if let service = result.credentialService,
           let value = result.credentialValue,
           !value.isEmpty {
            do {
                try KeychainManager.store(key: value, service: service, account: result.account.id.uuidString)
            } catch {
                return .failure(AccountProvisioningError(message: error.localizedDescription))
            }
        }
        switch ConfigManager.shared.save(config) {
        case .success:
            SetupExperienceStore.shared.markCompleted(.validatedAccount)
            return .success(())
        case .failure(let error):
            return .failure(AccountProvisioningError(message: error.description))
        }
    }

    static func testConnection(account: Account) async -> String {
        switch account.type {
        case .claudeCode, .codex, .gemini:
            if let status = LocalProviderLocator.status(for: account) {
                return status.isAvailable ? "✓ OK (\(status.displayPath))" : "✗ Missing local directory"
            }
            return "✗ Unsupported local provider"
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
                let end = Date()
                let start = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
                _ = try await client.fetchUsage(startDate: start, endDate: end)
                return "✓ OK"
            } catch {
                return "✗ \(error.localizedDescription)"
            }
        case .claudeAI:
            guard let token = try? KeychainManager.retrieve(service: AppConstants.keychainSessionTokenService, account: account.id.uuidString) else {
                return "✗ No session token stored"
            }
            let result = await ClaudeAIClient(sessionToken: token).fetchUsage()
            return result != nil ? "✓ OK" : "✗ Fetch failed (check session token)"
        }
    }
}
