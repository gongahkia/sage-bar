import Foundation

private struct WindsurfUserPageAnalyticsRequest: Encodable {
    var service_key: String
    var group_name: String?
}

private struct WindsurfTeamCreditBalanceRequest: Encodable {
    var service_key: String
}

private struct WindsurfUserPageAnalyticsResponse: Decodable {
    var userTableStats: [WindsurfUserTableStat]?
    var billingCycleStartDate: String?
    var billingCycleEndDate: String?
    var error: String?
}

private struct WindsurfUserTableStat: Decodable {
    var userId: String?
    var teamStatus: String?
    var promptCreditsUsed: Int?

    private enum CodingKeys: String, CodingKey {
        case userId
        case user_id
        case teamStatus
        case team_status
        case promptCreditsUsed
        case prompt_credits_used
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
            ?? c.decodeIfPresent(String.self, forKey: .user_id)
        teamStatus = try c.decodeIfPresent(String.self, forKey: .teamStatus)
            ?? c.decodeIfPresent(String.self, forKey: .team_status)
        promptCreditsUsed = c.decodeIntFlexible(forKeys: [.promptCreditsUsed, .prompt_credits_used])
    }
}

private struct WindsurfTeamCreditBalanceResponse: Decodable {
    var promptCreditsPerSeat: Int?
    var totalSeats: Int?
    var promptCreditsUsed: Int?
    var addOnCreditsUsed: Int?
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case promptCreditsPerSeat
        case prompt_credits_per_seat
        case totalSeats
        case total_seats
        case promptCreditsUsed
        case prompt_credits_used
        case addOnCreditsUsed
        case add_on_credits_used
        case error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptCreditsPerSeat = c.decodeIntFlexible(forKeys: [.promptCreditsPerSeat, .prompt_credits_per_seat])
        totalSeats = c.decodeIntFlexible(forKeys: [.totalSeats, .total_seats])
        promptCreditsUsed = c.decodeIntFlexible(forKeys: [.promptCreditsUsed, .prompt_credits_used])
        addOnCreditsUsed = c.decodeIntFlexible(forKeys: [.addOnCreditsUsed, .add_on_credits_used])
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

class WindsurfEnterpriseClient {
    private static let requestTimeoutSeconds: TimeInterval = 20
    private let serviceKey: String
    private let groupName: String?
    private let session: URLSession
    private let baseURL = URL(string: "https://server.codeium.com")!
    private let addOnCreditPricePer1KUSD = 40.0

    init(serviceKey: String, groupName: String? = nil, session: URLSession? = nil) {
        self.serviceKey = serviceKey
        self.groupName = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session ?? Self.makeDefaultSession()
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeoutSeconds
        config.timeoutIntervalForResource = requestTimeoutSeconds * 2
        return URLSession(configuration: config)
    }

    func validateAccess() async -> Bool {
        do {
            _ = try await fetchTeamCreditBalance()
            return true
        } catch {
            return false
        }
    }

    func fetchCurrentSnapshot(accountId: UUID, now: Date = Date()) async throws -> UsageSnapshot {
        async let analyticsTask = fetchUserPageAnalytics()
        async let balanceTask = fetchTeamCreditBalance()
        let analytics = try await analyticsTask
        let balance = try await balanceTask

        let promptCreditsUsed = max(0, analytics.userTableStats?
            .reduce(0) { partial, stat in
                partial + max(0, stat.promptCreditsUsed ?? 0)
            } ?? 0)
        let addOnCreditsUsed = max(0, balance.addOnCreditsUsed ?? 0)
        let addOnCostUSD = Double(addOnCreditsUsed) / 1000.0 * addOnCreditPricePer1KUSD

        return UsageSnapshot(
            accountId: accountId,
            timestamp: now,
            inputTokens: promptCreditsUsed,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalCostUSD: addOnCostUSD,
            modelBreakdown: [
                ModelUsage(
                    modelId: "windsurf-enterprise",
                    inputTokens: promptCreditsUsed,
                    outputTokens: 0,
                    cacheTokens: 0,
                    costUSD: addOnCostUSD
                )
            ],
            costConfidence: .estimated
        )
    }

    private func fetchUserPageAnalytics() async throws -> WindsurfUserPageAnalyticsResponse {
        var payload = WindsurfUserPageAnalyticsRequest(service_key: serviceKey, group_name: nil)
        if let groupName, !groupName.isEmpty {
            payload.group_name = groupName
        }
        let response: WindsurfUserPageAnalyticsResponse = try await post(
            path: "/api/v1/UserPageAnalytics",
            payload: payload
        )
        if let error = response.error, !error.isEmpty {
            throw APIError.serverError(400)
        }
        return response
    }

    private func fetchTeamCreditBalance() async throws -> WindsurfTeamCreditBalanceResponse {
        let response: WindsurfTeamCreditBalanceResponse = try await post(
            path: "/api/v1/GetTeamCreditBalance",
            payload: WindsurfTeamCreditBalanceRequest(service_key: serviceKey)
        )
        if let error = response.error, !error.isEmpty {
            throw APIError.serverError(400)
        }
        return response
    }

    private func post<T: Decodable, Body: Encodable>(path: String, payload: Body) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(payload)
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as! HTTPURLResponse
            try mapStatus(http.statusCode, headers: http.allHeaderFields)
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.decodingFailed
            }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func mapStatus(_ code: Int, headers: [AnyHashable: Any]) throws {
        switch code {
        case 200 ... 299:
            return
        case 401, 403:
            throw APIError.invalidKey
        case 429:
            let after = (headers["Retry-After"] as? String).flatMap(Int.init)
            throw APIError.rateLimited(retryAfter: after)
        default:
            throw APIError.serverError(code)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeIntFlexible(forKeys keys: [K]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: key), let parsed = Int(value) {
                return parsed
            }
        }
        return nil
    }
}
