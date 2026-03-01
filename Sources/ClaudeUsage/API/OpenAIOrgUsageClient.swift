import Foundation

private struct OpenAIBucketPage<Result: Decodable>: Decodable {
    var data: [OpenAIBucket<Result>]?
}

private struct OpenAIBucket<Result: Decodable>: Decodable {
    var start_time: Int?
    var end_time: Int?
    var results: [Result]?
}

private struct OpenAICompletionsUsageResult: Decodable {
    var model: String?
    var input_tokens: Int?
    var output_tokens: Int?
    var input_cached_tokens: Int?
    var input_audio_tokens: Int?
    var output_audio_tokens: Int?

    private enum CodingKeys: String, CodingKey {
        case model
        case input_tokens
        case output_tokens
        case input_cached_tokens
        case input_audio_tokens
        case output_audio_tokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        input_tokens = c.decodeIntFlexible(forKey: .input_tokens)
        output_tokens = c.decodeIntFlexible(forKey: .output_tokens)
        input_cached_tokens = c.decodeIntFlexible(forKey: .input_cached_tokens)
        input_audio_tokens = c.decodeIntFlexible(forKey: .input_audio_tokens)
        output_audio_tokens = c.decodeIntFlexible(forKey: .output_audio_tokens)
    }
}

private struct OpenAICostResult: Decodable {
    var line_item: String?
    var amount: OpenAICostAmount?
}

private struct OpenAICostAmount: Decodable {
    var value: Double?
    var currency: String?
}

private enum OpenAIGroupBy: String {
    case model
    case lineItem = "line_item"
}

private struct OpenAIModelAccumulator {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cost: Double = 0
}

class OpenAIOrgUsageClient {
    private static let requestTimeoutSeconds: TimeInterval = 25
    private let adminAPIKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.openai.com")!

    init(adminAPIKey: String, session: URLSession? = nil) {
        self.adminAPIKey = adminAPIKey
        self.session = session ?? Self.makeDefaultSession()
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeoutSeconds
        config.timeoutIntervalForResource = requestTimeoutSeconds * 2
        return URLSession(configuration: config)
    }

    func validateAccess(now: Date = Date()) async -> Bool {
        let dayStart = Calendar.current.startOfDay(for: now)
        let start = Int(dayStart.timeIntervalSince1970)
        let end = max(start + 1, Int(now.timeIntervalSince1970))
        do {
            _ = try await fetchCostBuckets(startUnix: start, endUnix: end)
            return true
        } catch {
            return false
        }
    }

    func fetchCurrentSnapshot(accountId: UUID, now: Date = Date()) async throws -> UsageSnapshot {
        let dayStart = Calendar.current.startOfDay(for: now)
        let start = Int(dayStart.timeIntervalSince1970)
        let end = max(start + 1, Int(now.timeIntervalSince1970))

        async let usageTask = fetchUsageBuckets(startUnix: start, endUnix: end)
        async let costsTask = fetchCostBuckets(startUnix: start, endUnix: end)

        let usageBuckets = try await usageTask
        let costBuckets = try await costsTask

        var totalsInput = 0
        var totalsOutput = 0
        var totalsCacheRead = 0
        var totalsCost = 0.0
        var perModel: [String: OpenAIModelAccumulator] = [:]

        for bucket in usageBuckets {
            for result in bucket.results ?? [] {
                let model = canonicalModelID(from: result.model, fallback: "openai-org")
                var acc = perModel[model] ?? OpenAIModelAccumulator()
                let input = max(0, result.input_tokens ?? 0) + max(0, result.input_audio_tokens ?? 0)
                let output = max(0, result.output_tokens ?? 0) + max(0, result.output_audio_tokens ?? 0)
                let cacheRead = max(0, result.input_cached_tokens ?? 0)
                acc.input += input
                acc.output += output
                acc.cacheRead += cacheRead
                perModel[model] = acc
                totalsInput += input
                totalsOutput += output
                totalsCacheRead += cacheRead
            }
        }

        for bucket in costBuckets {
            for result in bucket.results ?? [] {
                let cost = max(0, result.amount?.value ?? 0)
                totalsCost += cost
                let lineItem = canonicalModelID(from: result.line_item, fallback: "openai-org")
                var acc = perModel[lineItem] ?? OpenAIModelAccumulator()
                acc.cost += cost
                perModel[lineItem] = acc
            }
        }

        let detailedBreakdown = perModel.map {
            ModelUsage(
                modelId: $0.key,
                inputTokens: $0.value.input,
                outputTokens: $0.value.output,
                cacheTokens: $0.value.cacheRead,
                costUSD: $0.value.cost
            )
        }.sorted { $0.costUSD > $1.costUSD }

        var breakdown: [ModelUsage] = [
            ModelUsage(
                modelId: "openai-org",
                inputTokens: totalsInput,
                outputTokens: totalsOutput,
                cacheTokens: totalsCacheRead,
                costUSD: totalsCost
            )
        ]
        for item in detailedBreakdown where item.modelId != "openai-org" {
            breakdown.append(item)
        }

        return UsageSnapshot(
            accountId: accountId,
            timestamp: now,
            inputTokens: totalsInput,
            outputTokens: totalsOutput,
            cacheCreationTokens: 0,
            cacheReadTokens: totalsCacheRead,
            totalCostUSD: totalsCost,
            modelBreakdown: breakdown,
            costConfidence: .billingGrade
        )
    }

    private func fetchUsageBuckets(startUnix: Int, endUnix: Int) async throws -> [OpenAIBucket<OpenAICompletionsUsageResult>] {
        do {
            let page: OpenAIBucketPage<OpenAICompletionsUsageResult> = try await fetchBucketPage(
                path: "/v1/organization/usage/completions",
                startUnix: startUnix,
                endUnix: endUnix,
                groupBy: .model
            )
            return page.data ?? []
        } catch APIError.serverError(let code) where code == 400 {
            let page: OpenAIBucketPage<OpenAICompletionsUsageResult> = try await fetchBucketPage(
                path: "/v1/organization/usage/completions",
                startUnix: startUnix,
                endUnix: endUnix,
                groupBy: nil
            )
            return page.data ?? []
        }
    }

    private func fetchCostBuckets(startUnix: Int, endUnix: Int) async throws -> [OpenAIBucket<OpenAICostResult>] {
        do {
            let page: OpenAIBucketPage<OpenAICostResult> = try await fetchBucketPage(
                path: "/v1/organization/costs",
                startUnix: startUnix,
                endUnix: endUnix,
                groupBy: .lineItem
            )
            return page.data ?? []
        } catch APIError.serverError(let code) where code == 400 {
            let page: OpenAIBucketPage<OpenAICostResult> = try await fetchBucketPage(
                path: "/v1/organization/costs",
                startUnix: startUnix,
                endUnix: endUnix,
                groupBy: nil
            )
            return page.data ?? []
        }
    }

    private func fetchBucketPage<T: Decodable>(
        path: String,
        startUnix: Int,
        endUnix: Int,
        groupBy: OpenAIGroupBy?
    ) async throws -> OpenAIBucketPage<T> {
        var queryItems = [
            URLQueryItem(name: "start_time", value: "\(startUnix)"),
            URLQueryItem(name: "end_time", value: "\(endUnix)"),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "7"),
        ]
        if let groupBy {
            queryItems.append(URLQueryItem(name: "group_by", value: groupBy.rawValue))
        }
        let req = request(path: path, queryItems: queryItems)
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as! HTTPURLResponse
            try mapStatus(http.statusCode, headers: http.allHeaderFields)
            do {
                return try JSONDecoder().decode(OpenAIBucketPage<T>.self, from: data)
            } catch {
                throw APIError.decodingFailed
            }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func request(path: String, queryItems: [URLQueryItem]) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = queryItems
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(adminAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
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

    private func canonicalModelID(from raw: String?, fallback: String) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

private extension KeyedDecodingContainer {
    func decodeIntFlexible(forKey key: KeyedDecodingContainer<K>.Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key), let parsed = Int(value) {
            return parsed
        }
        return nil
    }
}
