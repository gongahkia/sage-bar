import Foundation

// MARK: – Errors

enum APIError: Error {
    case invalidKey
    case rateLimited(retryAfter: Int?)
    case serverError(Int)
    case decodingFailed
    case networkError(Error)
    case unsupported
}

// MARK: – Response types

struct AnthropicUsageResponse: Codable {
    var data: [AnthropicUsagePeriod]
    var has_more: Bool
    var first_id: String?
    var last_id: String?
}

struct AnthropicUsagePeriod: Codable {
    var start_time: String
    var end_time: String
    var input_tokens: Int
    var output_tokens: Int
    var cache_creation_input_tokens: Int
    var cache_read_input_tokens: Int
    var model: String
}

// MARK: – Client

private struct PriceEntry: Decodable {
    let inputPer1M: Double
    let outputPer1M: Double
}

class AnthropicAPIClient {
    static let pricingConstants: [String: (inputPer1M: Double, outputPer1M: Double)] = {
        guard let url = Bundle.module.url(forResource: "prices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: PriceEntry].self, from: data) else {
            ErrorLogger.shared.log("Failed to load prices.json from bundle", level: "WARN")
            return [:]
        }
        return raw.mapValues { ($0.inputPer1M, $0.outputPer1M) }
    }()

    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.anthropic.com")!

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    private func request(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func mapStatus(_ code: Int, headers: [AnyHashable: Any]) throws {
        switch code {
        case 200...299: return
        case 401: throw APIError.invalidKey
        case 429:
            let after = (headers["Retry-After"] as? String).flatMap(Int.init)
            throw APIError.rateLimited(retryAfter: after)
        default: throw APIError.serverError(code)
        }
    }

    func validateKey() async -> Bool {
        do {
            let req = request(path: "/v1/models")
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func fetchUsage(startDate: Date, endDate: Date) async throws -> AnthropicUsageResponse {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        let items = [
            URLQueryItem(name: "start_date", value: fmt.string(from: startDate)),
            URLQueryItem(name: "end_date", value: fmt.string(from: endDate)),
        ]
        let req = request(path: "/v1/usage", queryItems: items)
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as! HTTPURLResponse
            try mapStatus(http.statusCode, headers: http.allHeaderFields)
            return try JSONDecoder().decode(AnthropicUsageResponse.self, from: data)
        } catch let e as APIError { throw e } catch { throw APIError.networkError(error) }
    }

    func convertToSnapshots(_ response: AnthropicUsageResponse, accountId: UUID) -> [UsageSnapshot] {
        let fmt = ISO8601DateFormatter()
        return response.data.map { period in
            let price = Self.pricingConstants.first(where: { period.model.hasPrefix($0.key) })?.value ?? (0, 0)
            let costIn = Double(period.input_tokens) / 1_000_000 * price.inputPer1M
            let costOut = Double(period.output_tokens) / 1_000_000 * price.outputPer1M
            let costCacheCreate = Double(period.cache_creation_input_tokens) / 1_000_000 * price.inputPer1M * 1.25
            let costCacheRead = Double(period.cache_read_input_tokens) / 1_000_000 * price.inputPer1M * 0.1
            let date = fmt.date(from: period.start_time) ?? Date()
            return UsageSnapshot(
                accountId: accountId,
                timestamp: date,
                inputTokens: period.input_tokens,
                outputTokens: period.output_tokens,
                cacheCreationTokens: period.cache_creation_input_tokens,
                cacheReadTokens: period.cache_read_input_tokens,
                totalCostUSD: costIn + costOut + costCacheCreate + costCacheRead,
                modelBreakdown: [ModelUsage(modelId: period.model, inputTokens: period.input_tokens, outputTokens: period.output_tokens, costUSD: costIn + costOut)]
            )
        }
    }
}
