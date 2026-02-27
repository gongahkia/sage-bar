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
    private let session = URLSession(configuration: .ephemeral)

    func send(event: WebhookEvent, snapshot: UsageSnapshot, config: WebhookConfig) async throws {
        guard config.enabled, let url = URL(string: config.url), !config.url.isEmpty else { return }
        let data = buildPayload(event: event, snapshot: snapshot, template: config.payloadTemplate)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
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
        guard let url = URL(string: config.url) else { return .failure(APIError.networkError(URLError(.badURL))) }
        let dummy = UsageSnapshot(accountId: UUID(), timestamp: Date(), inputTokens: 0, outputTokens: 0,
                                  cacheCreationTokens: 0, cacheReadTokens: 0, totalCostUSD: 0, modelBreakdown: [])
        // fake event named "test"
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
