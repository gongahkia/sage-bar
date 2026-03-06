import Foundation

private struct GitHubCopilotMetricsDay: Decodable {
    var date: String?
    var total_active_users: Int?
    var total_engaged_users: Int?
    var copilot_ide_code_completions: GitHubCopilotIDECodeCompletions?
    var copilot_ide_chat: GitHubCopilotIDEChat?
    var copilot_dotcom_chat: GitHubCopilotDotcomChat?
    var copilot_dotcom_pull_requests: GitHubCopilotDotcomPullRequests?

    private enum CodingKeys: String, CodingKey {
        case date
        case total_active_users
        case total_engaged_users
        case copilot_ide_code_completions
        case copilot_ide_chat
        case copilot_dotcom_chat
        case copilot_dotcom_pull_requests
    }

    init(
        date: String?,
        total_active_users: Int?,
        total_engaged_users: Int?,
        copilot_ide_code_completions: GitHubCopilotIDECodeCompletions?,
        copilot_ide_chat: GitHubCopilotIDEChat?,
        copilot_dotcom_chat: GitHubCopilotDotcomChat?,
        copilot_dotcom_pull_requests: GitHubCopilotDotcomPullRequests?
    ) {
        self.date = date
        self.total_active_users = total_active_users
        self.total_engaged_users = total_engaged_users
        self.copilot_ide_code_completions = copilot_ide_code_completions
        self.copilot_ide_chat = copilot_ide_chat
        self.copilot_dotcom_chat = copilot_dotcom_chat
        self.copilot_dotcom_pull_requests = copilot_dotcom_pull_requests
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        total_active_users = c.decodeIntFlexible(forKey: .total_active_users)
        total_engaged_users = c.decodeIntFlexible(forKey: .total_engaged_users)
        copilot_ide_code_completions = try c.decodeIfPresent(GitHubCopilotIDECodeCompletions.self, forKey: .copilot_ide_code_completions)
        copilot_ide_chat = try c.decodeIfPresent(GitHubCopilotIDEChat.self, forKey: .copilot_ide_chat)
        copilot_dotcom_chat = try c.decodeIfPresent(GitHubCopilotDotcomChat.self, forKey: .copilot_dotcom_chat)
        copilot_dotcom_pull_requests = try c.decodeIfPresent(GitHubCopilotDotcomPullRequests.self, forKey: .copilot_dotcom_pull_requests)
    }
}

private struct GitHubCopilotIDECodeCompletions: Decodable {
    var total_engaged_users: Int?
    var editors: [GitHubCopilotIDECompletionsEditor]?
}

private struct GitHubCopilotIDECompletionsEditor: Decodable {
    var models: [GitHubCopilotIDECompletionsModel]?
}

private struct GitHubCopilotIDECompletionsModel: Decodable {
    var languages: [GitHubCopilotIDECompletionsLanguage]?
}

private struct GitHubCopilotIDECompletionsLanguage: Decodable {
    var total_code_suggestions: Int?
    var total_code_acceptances: Int?

    private enum CodingKeys: String, CodingKey {
        case total_code_suggestions
        case total_code_acceptances
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total_code_suggestions = c.decodeIntFlexible(forKey: .total_code_suggestions)
        total_code_acceptances = c.decodeIntFlexible(forKey: .total_code_acceptances)
    }
}

private struct GitHubCopilotIDEChat: Decodable {
    var total_engaged_users: Int?
    var editors: [GitHubCopilotIDEChatEditor]?
}

private struct GitHubCopilotIDEChatEditor: Decodable {
    var models: [GitHubCopilotIDEChatModel]?
}

private struct GitHubCopilotIDEChatModel: Decodable {
    var total_chats: Int?
    var total_chat_insertion_events: Int?
    var total_chat_copy_events: Int?

    private enum CodingKeys: String, CodingKey {
        case total_chats
        case total_chat_insertion_events
        case total_chat_copy_events
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total_chats = c.decodeIntFlexible(forKey: .total_chats)
        total_chat_insertion_events = c.decodeIntFlexible(forKey: .total_chat_insertion_events)
        total_chat_copy_events = c.decodeIntFlexible(forKey: .total_chat_copy_events)
    }
}

private struct GitHubCopilotDotcomChat: Decodable {
    var total_engaged_users: Int?
    var models: [GitHubCopilotDotcomChatModel]?
}

private struct GitHubCopilotDotcomChatModel: Decodable {
    var total_chats: Int?

    private enum CodingKeys: String, CodingKey {
        case total_chats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total_chats = c.decodeIntFlexible(forKey: .total_chats)
    }
}

private struct GitHubCopilotDotcomPullRequests: Decodable {
    var total_engaged_users: Int?
    var repositories: [GitHubCopilotDotcomPullRequestsRepository]?
}

private struct GitHubCopilotDotcomPullRequestsRepository: Decodable {
    var models: [GitHubCopilotDotcomPullRequestsModel]?
}

private struct GitHubCopilotDotcomPullRequestsModel: Decodable {
    var total_pr_summaries_created: Int?

    private enum CodingKeys: String, CodingKey {
        case total_pr_summaries_created
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total_pr_summaries_created = c.decodeIntFlexible(forKey: .total_pr_summaries_created)
    }
}

class GitHubCopilotMetricsClient {
    private static let requestTimeoutSeconds: TimeInterval = 20
    private let token: String
    private let organization: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.github.com")!

    init(token: String, organization: String, session: URLSession? = nil) {
        self.token = token
        self.organization = organization
        self.session = session ?? Self.makeDefaultSession()
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeoutSeconds
        config.timeoutIntervalForResource = requestTimeoutSeconds * 2
        return URLSession(configuration: config)
    }

    func validateAccess(now: Date = Date()) async -> Bool {
        do {
            _ = try await fetchLatestMetricsDay(now: now)
            return true
        } catch {
            return false
        }
    }

    func fetchCurrentSnapshot(accountId: UUID, now: Date = Date()) async throws -> UsageSnapshot {
        let day = try await fetchLatestMetricsDay(now: now)

        let completionsSuggestions = day.copilot_ide_code_completions?.editors?
            .flatMap { $0.models ?? [] }
            .flatMap { $0.languages ?? [] }
            .reduce(0) { partial, language in
                partial + max(0, language.total_code_suggestions ?? 0)
            } ?? 0

        let completionsAcceptances = day.copilot_ide_code_completions?.editors?
            .flatMap { $0.models ?? [] }
            .flatMap { $0.languages ?? [] }
            .reduce(0) { partial, language in
                partial + max(0, language.total_code_acceptances ?? 0)
            } ?? 0

        let ideChats = day.copilot_ide_chat?.editors?
            .flatMap { $0.models ?? [] }
            .reduce(0) { partial, model in
                partial + max(0, model.total_chats ?? 0)
            } ?? 0

        let ideChatInsertions = day.copilot_ide_chat?.editors?
            .flatMap { $0.models ?? [] }
            .reduce(0) { partial, model in
                partial + max(0, model.total_chat_insertion_events ?? 0)
            } ?? 0

        let ideChatCopies = day.copilot_ide_chat?.editors?
            .flatMap { $0.models ?? [] }
            .reduce(0) { partial, model in
                partial + max(0, model.total_chat_copy_events ?? 0)
            } ?? 0

        let dotcomChats = day.copilot_dotcom_chat?.models?
            .reduce(0) { partial, model in
                partial + max(0, model.total_chats ?? 0)
            } ?? 0

        let prSummaries = day.copilot_dotcom_pull_requests?.repositories?
            .flatMap { $0.models ?? [] }
            .reduce(0) { partial, model in
                partial + max(0, model.total_pr_summaries_created ?? 0)
            } ?? 0

        let inputActivity = completionsSuggestions + ideChats + dotcomChats + prSummaries
        let outputActivity = completionsAcceptances + ideChatInsertions + ideChatCopies + dotcomChats + prSummaries
        let fallbackActivity = max(0, day.total_active_users ?? 0) + max(0, day.total_engaged_users ?? 0)
        let totalInput = inputActivity > 0 ? inputActivity : fallbackActivity
        let totalOutput = outputActivity > 0 ? outputActivity : max(0, day.total_engaged_users ?? 0)

        let detailedBreakdown = [
            ModelUsage(
                modelId: "copilot-ide-code-completions",
                inputTokens: completionsSuggestions,
                outputTokens: completionsAcceptances,
                cacheTokens: 0,
                costUSD: 0
            ),
            ModelUsage(
                modelId: "copilot-ide-chat",
                inputTokens: ideChats,
                outputTokens: ideChatInsertions + ideChatCopies,
                cacheTokens: 0,
                costUSD: 0
            ),
            ModelUsage(
                modelId: "copilot-dotcom-chat",
                inputTokens: dotcomChats,
                outputTokens: dotcomChats,
                cacheTokens: 0,
                costUSD: 0
            ),
            ModelUsage(
                modelId: "copilot-dotcom-pr",
                inputTokens: prSummaries,
                outputTokens: prSummaries,
                cacheTokens: 0,
                costUSD: 0
            ),
        ].filter {
            ($0.inputTokens + $0.outputTokens + $0.cacheTokens) > 0
        }

        var breakdown: [ModelUsage] = [
            ModelUsage(
                modelId: "copilot-metrics",
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheTokens: 0,
                costUSD: 0
            )
        ]
        breakdown.append(contentsOf: detailedBreakdown)

        return UsageSnapshot(
            accountId: accountId,
            timestamp: now,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: 0,
            modelBreakdown: breakdown,
            costConfidence: .estimated
        )
    }

    private func fetchLatestMetricsDay(now: Date) async throws -> GitHubCopilotMetricsDay {
        let cal = Calendar(identifier: .gregorian)
        let sinceDate = cal.date(byAdding: .day, value: -14, to: now) ?? now
        let sinceRaw = iso8601DateTime(sinceDate)
        let untilRaw = iso8601DateTime(now)

        var comps = URLComponents(url: baseURL.appendingPathComponent("/orgs/\(organization)/copilot/metrics"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "since", value: sinceRaw),
            URLQueryItem(name: "until", value: untilRaw),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: "1"),
        ]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("sage-bar", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                ErrorLogger.shared.log("GitHub Copilot metrics fetch received non-HTTP response", level: "WARN")
                throw APIError.networkError(URLError(.badServerResponse))
            }
            try mapStatus(http.statusCode)
            let days: [GitHubCopilotMetricsDay]
            do {
                days = try JSONDecoder().decode([GitHubCopilotMetricsDay].self, from: data)
            } catch {
                throw APIError.decodingFailed
            }
            guard !days.isEmpty else {
                return GitHubCopilotMetricsDay(date: nil, total_active_users: 0, total_engaged_users: 0, copilot_ide_code_completions: nil, copilot_ide_chat: nil, copilot_dotcom_chat: nil, copilot_dotcom_pull_requests: nil)
            }
            let latest = days.max {
                ($0.date ?? "") < ($1.date ?? "")
            }
            return latest ?? days[0]
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func iso8601DateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func mapStatus(_ code: Int) throws {
        switch code {
        case 200 ... 299:
            return
        case 401, 403:
            throw APIError.invalidKey
        case 429:
            throw APIError.rateLimited(retryAfter: nil)
        default:
            throw APIError.serverError(code)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeIntFlexible(forKey key: K) -> Int? {
        if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
            return intValue
        }
        if let doubleValue = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(doubleValue)
        }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key), let parsed = Int(stringValue) {
            return parsed
        }
        return nil
    }
}
