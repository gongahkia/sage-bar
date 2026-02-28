import Foundation

struct OpenAIOrgCredentialPayload: Codable, Equatable {
    var adminKey: String

    init(adminKey: String) {
        self.adminKey = adminKey
    }
}

struct WindsurfEnterpriseCredentialPayload: Codable, Equatable {
    var serviceKey: String
    var groupName: String?

    init(serviceKey: String, groupName: String? = nil) {
        self.serviceKey = serviceKey
        self.groupName = groupName
    }
}

struct GitHubCopilotCredentialPayload: Codable, Equatable {
    var token: String
    var organization: String

    init(token: String, organization: String) {
        self.token = token
        self.organization = organization
    }
}

enum ProviderCredentialCodec {
    static func encodeOpenAI(_ payload: OpenAIOrgCredentialPayload) -> String {
        encodeDictionary([
            "admin_key": payload.adminKey
        ])
    }

    static func encodeWindsurf(_ payload: WindsurfEnterpriseCredentialPayload) -> String {
        var obj: [String: String] = ["service_key": payload.serviceKey]
        if let groupName = payload.groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !groupName.isEmpty {
            obj["group_name"] = groupName
        }
        return encodeDictionary(obj)
    }

    static func encodeCopilot(_ payload: GitHubCopilotCredentialPayload) -> String {
        encodeDictionary([
            "token": payload.token,
            "organization": payload.organization
        ])
    }

    static func openAIAdminKey(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let obj = decodeDictionary(raw: trimmed),
           let key = firstString(
                in: obj,
                keys: ["admin_key", "adminKey", "openai_admin_key", "openAIAdminKey", "api_key", "apiKey", "key"]
           ) {
            return key
        }
        // Backward compatibility with raw key storage.
        if !trimmed.isEmpty, !trimmed.hasPrefix("{") {
            return trimmed
        }
        return nil
    }

    static func windsurf(from raw: String) -> WindsurfEnterpriseCredentialPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = decodeDictionary(raw: trimmed) else { return nil }
        guard let serviceKey = firstString(
            in: obj,
            keys: ["service_key", "serviceKey", "api_key", "apiKey", "key"]
        ) else { return nil }
        let groupName = firstString(in: obj, keys: ["group_name", "groupName", "team", "team_name"])
        return WindsurfEnterpriseCredentialPayload(serviceKey: serviceKey, groupName: groupName)
    }

    static func copilot(from raw: String) -> GitHubCopilotCredentialPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = decodeDictionary(raw: trimmed) else { return nil }
        guard let token = firstString(in: obj, keys: ["token", "github_token", "githubToken", "api_key", "apiKey"]),
              let organization = firstString(in: obj, keys: ["organization", "org", "org_slug", "orgSlug"]) else {
            return nil
        }
        return GitHubCopilotCredentialPayload(token: token, organization: organization)
    }

    private static func encodeDictionary(_ obj: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let raw = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return raw
    }

    private static func decodeDictionary(raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func firstString(in obj: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = obj[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
