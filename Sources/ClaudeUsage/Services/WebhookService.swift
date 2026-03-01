import Foundation

enum WebhookEvent {
    case thresholdBreached(limitUSD: Double)
    case dailyDigest
    case weeklyDigest
    var name: String {
        switch self {
        case .thresholdBreached: return "threshold"
        case .dailyDigest: return "daily_digest"
        case .weeklyDigest: return "weekly_summary"
        }
    }
}

class WebhookService {
    let maxRetries: Int
    private let session: URLSession
    private let baseRetryDelayNanos: UInt64

    init(session: URLSession? = nil, maxRetries: Int = 2, baseRetryDelayNanos: UInt64 = 250_000_000) {
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.maxRetries = maxRetries
        self.baseRetryDelayNanos = baseRetryDelayNanos
    }

    func send(event: WebhookEvent, snapshot: UsageSnapshot, config: WebhookConfig) async throws {
        guard config.enabled, !config.url.isEmpty else { return }
        guard let url = URL(string: config.url), url.scheme == "https" else {
            let msg = "Webhook URL '\(config.url)' is invalid or missing https:// scheme"
            ErrorLogger.shared.log(msg, level: "WARN")
            throw APIError.networkError(URLError(.badURL))
        }
        let data = buildPayload(event: event, snapshot: snapshot, template: config.payloadTemplate)
        try validateTemplateJSONIfNeeded(template: config.payloadTemplate, payload: data)
        var lastError: Error?
        let idempotencyKey = UUID().uuidString
        for attempt in 0...maxRetries {
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
                req.setValue(idempotencyKey, forHTTPHeaderField: "X-Idempotency-Key")
                req.httpBody = data
                let (_, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                let statusCode = http?.statusCode ?? 0
                if (200...299).contains(statusCode) {
                    return
                }
                let apiError: APIError
                if statusCode == 429 {
                    apiError = .rateLimited(retryAfter: retryAfterSeconds(from: http))
                } else {
                    apiError = .serverError(statusCode)
                }
                lastError = apiError
                if attempt >= maxRetries || !isRetryableStatus(statusCode) {
                    throw apiError
                }
                let delay = retryDelayNanos(attempt: attempt, retryAfterSeconds: retryAfterSeconds(from: http))
                try await Task.sleep(nanoseconds: delay)
            } catch let e as APIError {
                lastError = e
                if attempt >= maxRetries {
                    throw e
                }
            } catch {
                ErrorLogger.shared.log("Webhook send failed (attempt \(attempt+1)): \(error.localizedDescription)", level: "WARN")
                lastError = error
                let urlError = error as? URLError
                if attempt >= maxRetries || !isTransientURLError(urlError) {
                    throw error
                }
                let delay = retryDelayNanos(attempt: attempt, retryAfterSeconds: nil)
                try await Task.sleep(nanoseconds: delay)
            }
        }
        if let e = lastError { throw e }
    }

    func buildPayload(event: WebhookEvent, snapshot: UsageSnapshot, template: String?) -> Data {
        if let tpl = template, !tpl.isEmpty {
            var s = tpl
            s = s.replacingOccurrences(of: "{{event}}", with: event.name)
            s = s.replacingOccurrences(of: "{{account}}", with: snapshot.accountId.uuidString)
            s = s.replacingOccurrences(of: "{{cost}}", with: String(format: "%.4f", snapshot.totalCostUSD))
            s = s.replacingOccurrences(of: "{{tokens}}", with: "\(snapshot.inputTokens + snapshot.outputTokens)")
            s = s.replacingOccurrences(of: "{{date}}", with: SharedDateFormatters.iso8601InternetDateTime.string(from: snapshot.timestamp))
            return s.data(using: .utf8) ?? Data()
        }
        let obj: [String: Any] = [
            "event": event.name,
            "account": snapshot.accountId.uuidString,
            "timestamp": SharedDateFormatters.iso8601InternetDateTime.string(from: snapshot.timestamp),
            "cost_usd": snapshot.totalCostUSD,
            "input_tokens": snapshot.inputTokens,
            "output_tokens": snapshot.outputTokens,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    func sendTest(config: WebhookConfig) async -> Result<Void, Error> {
        guard let url = URL(string: config.url), url.scheme == "https" else {
            return .failure(APIError.networkError(URLError(.badURL)))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let obj: [String: Any] = [
            "event": "test",
            "account": "test",
            "timestamp": SharedDateFormatters.iso8601InternetDateTime.string(from: Date()),
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: obj)
        do {
            let (_, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else {
                return .failure(APIError.serverError(0))
            }
            return .success(())
        } catch { return .failure(error) }
    }

    private func isRetryableStatus(_ statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    private func retryAfterSeconds(from response: HTTPURLResponse?) -> Int? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Int(value)
    }

    private func retryDelayNanos(attempt: Int, retryAfterSeconds: Int?) -> UInt64 {
        RetryPolicy.delayNanos(
            attempt: attempt,
            retryAfterSeconds: retryAfterSeconds,
            baseDelayNanos: baseRetryDelayNanos,
            maxExponent: 6,
            jitterFraction: 0.30
        )
    }

    private func isTransientURLError(_ error: URLError?) -> Bool {
        guard let error else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func validateTemplateJSONIfNeeded(template: String?, payload: Data) throws {
        guard let template = template?.trimmingCharacters(in: .whitespacesAndNewlines),
              !template.isEmpty,
              template.hasPrefix("{") || template.hasPrefix("[") else { return }
        do {
            _ = try JSONSerialization.jsonObject(with: payload)
        } catch {
            ErrorLogger.shared.log("Webhook payload template produced invalid JSON after substitution", level: "WARN")
            throw APIError.decodingFailed
        }
    }
}
