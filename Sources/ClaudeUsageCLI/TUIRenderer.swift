import Foundation

// MARK: – Logo

private let claudeLogo: [String] = [
    "   ██████╗    ",
    "  ██╔════╝    ",
    "  ██║         ",
    "  ██║         ",
    "  ██║         ",
    "  ╚██████╗    ",
    "   ╚═════╝    ",
    "  Claude ™    ",
]

// MARK: – Renderer

struct TUIRenderer {
    let snapshots: [UsageSnapshot]
    let config: TUIConfig
    let noColor: Bool

    private func label(_ s: String) -> String {
        noColor ? s : "\(ANSIColor.cyan.on)\(s)\(ANSIColor.off)"
    }
    private func value(_ s: String) -> String {
        noColor ? s : "\(ANSIColor.white.on)\(s)\(ANSIColor.off)"
    }
    private func separator() -> String {
        let line = String(repeating: config.separatorChar, count: 40)
        return noColor ? line : "\(ANSIColor.brightBlack.on)\(line)\(ANSIColor.off)"
    }

    func render() -> String {
        var out = ""
        for (idx, snap) in snapshots.enumerated() {
            if idx > 0 { out += separator() + "\n" }
            out += renderSnapshot(snap)
        }
        return out
    }

    private func renderSnapshot(_ snap: UsageSnapshot) -> String {
        let fields = buildFields(snap)
        var rows: [String] = []
        let logoLines = config.showLogo ? claudeLogo : []
        let maxRows = max(logoLines.count, fields.count)
        for i in 0..<maxRows {
            let logo = i < logoLines.count ? logoLines[i] : String(repeating: " ", count: 15)
            let field = i < fields.count ? fields[i] : ""
            rows.append("  \(logo)  \(field)")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func buildFields(_ snap: UsageSnapshot) -> [String] {
        let lw = config.labelWidth
        var result: [String] = []
        for field in config.layout {
            switch field {
            case "input_tokens":
                result.append(row("Input Tokens", v: snap.inputTokens.formatted(), lw: lw))
            case "output_tokens":
                result.append(row("Output Tokens", v: snap.outputTokens.formatted(), lw: lw))
            case "cache_tokens":
                let ct = snap.cacheCreationTokens + snap.cacheReadTokens
                result.append(row("Cache Tokens", v: ct.formatted(), lw: lw))
            case "cost_usd":
                result.append(row("Cost Today", v: String(format: "$%.4f", snap.totalCostUSD), lw: lw))
            case "last_updated":
                let fmt = DateFormatter(); fmt.dateStyle = .none; fmt.timeStyle = .short
                result.append(row("Updated", v: fmt.string(from: snap.timestamp), lw: lw))
            case "model_breakdown":
                for m in snap.modelBreakdown {
                    result.append(row("  " + m.modelId, v: String(format: "$%.4f", m.costUSD), lw: lw))
                }
            default: break
            }
        }
        return result
    }

    private func row(_ lbl: String, v: String, lw: Int) -> String {
        let padded = lbl.padding(toLength: lw, withPad: " ", startingAt: 0)
        return "\(label(padded)) \(value(v))"
    }

    // MARK: – Forecast block

    func renderForecast(_ f: ForecastSnapshot) -> String {
        let half = String(repeating: config.separatorChar, count: 20)
        var out = noColor ? half : "\(ANSIColor.brightBlack.on)\(half)\(ANSIColor.off)"
        out += "\n"
        out += row("EOD Projected", v: String(format: "$%.2f", f.projectedEODCostUSD), lw: config.labelWidth) + "\n"
        out += row("EOW Projected", v: String(format: "$%.2f", f.projectedEOWCostUSD), lw: config.labelWidth) + "\n"
        out += row("EOM Projected", v: String(format: "$%.2f", f.projectedEOMCostUSD), lw: config.labelWidth) + "\n"
        return out
    }
}

// MARK: – UsageSnapshot/ForecastSnapshot stubs (shared from CLI container)

struct UsageSnapshot: Codable {
    var accountId: UUID
    var timestamp: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var totalCostUSD: Double
    var modelBreakdown: [ModelUsage]
}

struct ModelUsage: Codable {
    var modelId: String
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
}

struct ForecastSnapshot: Codable {
    var accountId: UUID
    var generatedAt: Date
    var projectedEODCostUSD: Double
    var projectedEOWCostUSD: Double
    var projectedEOMCostUSD: Double
    var burnRatePerHour: Double
}

struct TUIConfig: Codable {
    var layout: [String]
    var colorScheme: String
    var showLogo: Bool
    var separatorChar: String
    var labelWidth: Int
}
