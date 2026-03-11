import Foundation

struct ClaudeAIUsage {
    var messagesRemaining: Int
    var messagesUsed: Int
    var resetAt: Date?
}

struct ClaudeAIUsageResponse: Decodable {
    struct MessageLimit: Decodable {
        let remaining: Int
        let used: Int?
        let resetAt: Date?
    }
    let messageLimit: MessageLimit
}

enum ClaudeAIError: Error {
    case unauthorized
    case forbidden
    case invalidResponse
    case networkError(Error)
}

struct ClaudeAIClient {
    private let sessionToken: String
    private let session: URLSession

    init(sessionToken: String) {
        self.sessionToken = sessionToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    internal init(sessionToken: String, session: URLSession) {
        self.sessionToken = sessionToken
        self.session = session
    }

    func fetchUsageResult() async -> Result<ClaudeAIUsage, ClaudeAIError> {
        do {
            let response = try await fetchRemainingUsage()
            return .success(
                ClaudeAIUsage(
                    messagesRemaining: response.messageLimit.remaining,
                    messagesUsed: response.messageLimit.used ?? 0,
                    resetAt: response.messageLimit.resetAt
                )
            )
        } catch let error as ClaudeAIError {
            return .failure(error)
        } catch {
            return .failure(.networkError(error))
        }
    }

    func fetchUsage() async -> ClaudeAIUsage? {
        switch await fetchUsageResult() {
        case .success(let usage):
            return usage
        case .failure(let error):
            ErrorLogger.shared.log("ClaudeAI fetchUsage failed: \(error)", level: "WARN")
            return nil
        }
    }

    func fetchRemainingUsage() async throws -> ClaudeAIUsageResponse {
        var req = URLRequest(url: URL(string: "https://claude.ai/api/usage")!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("sessionKey=\(sessionToken)", forHTTPHeaderField: "Cookie")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ClaudeAIError.networkError(error)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw ClaudeAIError.unauthorized }
            if http.statusCode == 403 { throw ClaudeAIError.forbidden }
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode(ClaudeAIUsageResponse.self, from: data)
        } catch {
            throw ClaudeAIError.invalidResponse
        }
    }
}
