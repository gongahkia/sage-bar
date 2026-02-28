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

    init(session: URLSession? = nil, maxRetries: Int = 2) {
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.maxRetries = maxRetries
    }

    func send(event: WebhookEvent, snapshot: UsageSnapshot, config: WebhookConfig) async throws {
        guard config.enabled, !config.url.isEmpty else { return }
        guard let url = URL(string: config.url), url.scheme == "https" else {
            let msg = "Webhook URL '\(config.url)' is invalid or missing https:// scheme"
            ErrorLogger.shared.log(msg, level: "WARN")
            throw APIError.networkError(URLError(.badURL))
        }
        let data = buildPayload(event: event, snapshot: snapshot, template: config.payloadTemplate)
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = data
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 503, attempt < maxRetries {
                    lastError = APIError.serverError(503)
                    continue // retry
                }
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
                }
                return // success
            } catch let e as APIError { lastError = e; if attempt >= maxRetries { throw e }
            } catch {
                ErrorLogger.shared.log("Webhook send failed (attempt \(attempt+1)): \(error.localizedDescription)", level: "WARN")
                lastError = error
                if attempt >= maxRetries { throw error }
            }
        }
        if let e = lastError { throw e }
    }

    func buildPayload(event: WebhookEvent, snapshot: UsageSnapshot, template: String?) -> Data {
        let iso = ISO8601DateFormatter()
        if let tpl = template, !tpl.isEmpty {
            var s = tpl
            s = s.replacingOccurrences(of: "{{event}}", with: event.name)
            s = s.replacingOccurrences(of: "{{account}}", with: snapshot.accountId.uuidString)
            s = s.replacingOccurrences(of: "{{cost}}", with: String(format: "%.4f", snapshot.totalCostUSD))
            s = s.replacingOccurrences(of: "{{tokens}}", with: "\(snapshot.inputTokens + snapshot.outputTokens)")
            s = s.replacingOccurrences(of: "{{date}}", with: iso.string(from: snapshot.timestamp))
            return s.data(using: .utf8) ?? Data()
        }
        let obj: [String: Any] = [
            "event": event.name,
            "account": snapshot.accountId.uuidString,
            "timestamp": iso.string(from: snapshot.timestamp),
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
        let obj: [String: Any] = ["event":"test","account":"test","timestamp":ISO8601DateFormatter().string(from:Date())]
        req.httpBody = try? JSONSerialization.data(withJSONObject: obj)
        do {
            let (_, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else {
                return .failure(APIError.serverError(0))
            }
            return .success(())
        } catch { return .failure(error) }
    }
}
