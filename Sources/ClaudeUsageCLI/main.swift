import Foundation
import ClaudeUsageCore
import TOMLKit
import Darwin

// MARK: – Shared container path (mirrors AppConstants)
let appGroup = "group.dev.claudeusage"
let sharedContainer: URL = {
    if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
        return url
    }
    return FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage")
}()
let cacheFile = sharedContainer.appendingPathComponent("usage_cache.json")
let lastGoodCacheFile = sharedContainer.appendingPathComponent("usage_cache.last_good.json")
let forecastFile = sharedContainer.appendingPathComponent("forecast_cache.json")
let watchLockFile = sharedContainer.appendingPathComponent("cli_watch.lock")
let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-usage")
let configFile = configDir.appendingPathComponent("config.toml")

private struct UsageCachePayload: Codable {
    var schemaVersion: Int
    var snapshots: [UsageSnapshot]
}

private struct ForecastCachePayload: Codable {
    var schemaVersion: Int
    var forecasts: [ForecastSnapshot]
}

private struct ModelHintPayload: Codable {
    enum SavingsConfidence: String, Codable {
        case measured
        case profileEstimated
        case heuristicEstimated
    }

    var accountId: UUID
    var date: Date
    var expensiveModelTokens: Int
    var cheaperAlternativeExists: Bool
    var estimatedSavingsUSD: Double
    var recommendedModel: String
    var savingsConfidence: SavingsConfidence

    enum CodingKeys: String, CodingKey {
        case accountId
        case date
        case expensiveModelTokens
        case cheaperAlternativeExists
        case estimatedSavingsUSD
        case recommendedModel
        case savingsConfidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        date = try c.decode(Date.self, forKey: .date)
        expensiveModelTokens = try c.decode(Int.self, forKey: .expensiveModelTokens)
        cheaperAlternativeExists = try c.decode(Bool.self, forKey: .cheaperAlternativeExists)
        estimatedSavingsUSD = try c.decode(Double.self, forKey: .estimatedSavingsUSD)
        recommendedModel = try c.decode(String.self, forKey: .recommendedModel)
        savingsConfidence = try c.decodeIfPresent(SavingsConfidence.self, forKey: .savingsConfidence) ?? .measured
    }
}

private func providerName(forRecommendedModel model: String) -> String {
    let normalized = model.lowercased()
    if normalized.hasPrefix("claude") { return "Anthropic" }
    if normalized.hasPrefix("gpt") || normalized.hasPrefix("o1") || normalized.hasPrefix("o3") || normalized.hasPrefix("o4") {
        return "OpenAI"
    }
    if normalized.hasPrefix("gemini") { return "Google Gemini" }
    return "Unknown"
}

private func confidenceLabel(_ confidence: ModelHintPayload.SavingsConfidence) -> String {
    switch confidence {
    case .measured: return "measured"
    case .profileEstimated: return "profile"
    case .heuristicEstimated: return "heuristic"
    }
}

private func pad(_ value: String, width: Int) -> String {
    let clipped = value.count > width ? String(value.prefix(width)) : value
    if clipped.count >= width { return clipped }
    return clipped + String(repeating: " ", count: width - clipped.count)
}

private func acquireWatchLock(_ url: URL) -> Int32? {
    let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { return nil }
    let pidLine = "\(getpid())\n"
    _ = pidLine.withCString { write(fd, $0, strlen($0)) }
    return fd
}

private func releaseWatchLock(_ fd: Int32, url: URL) {
    close(fd)
    try? FileManager.default.removeItem(at: url)
}

private func loadConfigJSONObject(from file: URL) -> [String: Any]? {
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    guard let table = try? TOMLTable(string: raw) else { return nil }
    let json = table.convert(to: .json)
    guard let data = json.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return obj
}

// MARK: – Version

let appVersion = "1.0.0"

// MARK: – Arg parsing

var accountFilter: String? = nil
var noColor = false
var formatJSON = false
var showForecast = false
var showHistory = false
var showHeatmap = false
var showErrors = false
var errorsCount = 20
var showConfig = false
var showModels = false
var showOptimizerHints = false
var sinceDate: Date? = nil
var sinceParseError: String? = nil
var watchInterval: Int? = nil

var args = CommandLine.arguments.dropFirst()
var iter = args.makeIterator()
while let arg = iter.next() {
    switch arg {
    case "--version":
        print("claude-usage \(appVersion)")
        exit(0)
    case "--account": accountFilter = iter.next()
    case "--no-color": noColor = true
    case "--format":
        if iter.next() == "json" { formatJSON = true }
    case "--forecast": showForecast = true
    case "--history": showHistory = true
    case "--heatmap": showHeatmap = true
    case "--config": showConfig = true
    case "--models": showModels = true
    case "--optimizer-hints": showOptimizerHints = true
    case "--since":
        if let raw = iter.next() {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
            if let parsed = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
                sinceDate = parsed
            } else {
                sinceParseError = "Invalid --since date '\(raw)'. Use YYYY-MM-DD or ISO8601."
            }
        }
    case "--watch":
        if let raw = iter.next(), let n = Int(raw) { watchInterval = n } else { watchInterval = 30 }
    case "--errors": showErrors = true
    case "--help":
        print("claude-usage [--account NAME] [--no-color] [--format json] [--forecast] [--history] [--heatmap] [--models] [--optimizer-hints] [--since DATE] [--watch N] [--config] [--errors[=N]] [--version]")
        exit(0)
    default:
        if arg.hasPrefix("--errors="), let n = Int(arg.dropFirst("--errors=".count)) {
            showErrors = true; errorsCount = n
        }
    }
}

if let sinceParseError {
    fputs("\(sinceParseError)\n", stderr)
    exit(3)
}

// MARK: – --config

if showConfig {
    let cfgPath = configDir.appendingPathComponent("config.toml")
    if var obj = loadConfigJSONObject(from: cfgPath) {
        if var wh = obj["webhook"] as? [String: Any], let url = wh["url"] as? String, !url.isEmpty {
            wh["url"] = "***"; obj["webhook"] = wh
        }
        let out = (try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print(out)
    } else {
        print("{}")
    }
    exit(0)
}

// MARK: – --errors

if showErrors {
    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-usage/errors.log")
    guard let text = try? String(contentsOf: logFile, encoding: .utf8) else {
        print("No error log found at \(logFile.path)")
        exit(0)
    }
    let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
    lines.suffix(errorsCount).forEach { print($0) }
    exit(0)
}

// MARK: – Load cache

let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

func decodeSnapshots(from data: Data, using decoder: JSONDecoder) -> [UsageSnapshot]? {
    let snapshotsFromVersioned = try? decoder.decode(UsageCachePayload.self, from: data).snapshots
    let snapshotsFromLegacy = try? decoder.decode([UsageSnapshot].self, from: data)
    return snapshotsFromVersioned ?? snapshotsFromLegacy
}

guard FileManager.default.fileExists(atPath: cacheFile.path),
      let data = try? Data(contentsOf: cacheFile) else {
    fputs("Run ClaudeUsage.app first to populate data\n", stderr)
    exit(1)
}

var snapshots: [UsageSnapshot]? = decodeSnapshots(from: data, using: decoder)
if snapshots != nil {
    try? data.write(to: lastGoodCacheFile, options: .atomic)
}
if snapshots == nil,
   let backupData = try? Data(contentsOf: lastGoodCacheFile),
   let backupSnapshots = decodeSnapshots(from: backupData, using: decoder) {
    snapshots = backupSnapshots
    fputs("Parse error: primary cache malformed, using last-known-good cache backup\n", stderr)
}
guard var snapshots else {
    fputs("Parse error: cache file malformed\n", stderr)
    exit(2)
}

// filter by account name/id; validate filter against config accounts
var matchedAccountIDSetForFilter: Set<String>? = nil
if let filter = accountFilter {
    let cfgPath = configDir.appendingPathComponent("config.toml")
    var accountRows: [(id: String, name: String)] = []
    if let obj = loadConfigJSONObject(from: cfgPath),
       let accounts = obj["accounts"] as? [[String: Any]] {
        accountRows = accounts.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let name = (row["name"] as? String) ?? ""
            return (id, name)
        }
    }
    let filterLow = filter.lowercased()
    let exactIDMatches = accountRows.filter { $0.id.lowercased() == filterLow }.map(\.id)
    let nameMatches = accountRows.filter { $0.name.lowercased() == filterLow }.map(\.id)
    let idPrefixMatches = accountRows.filter { $0.id.lowercased().hasPrefix(filterLow) }.map(\.id)

    let matchedIDs: [String]
    if !exactIDMatches.isEmpty {
        matchedIDs = exactIDMatches
    } else if nameMatches.count == 1 {
        matchedIDs = nameMatches
    } else if nameMatches.count > 1 {
        fputs("Account name '\(filter)' is ambiguous; matched \(nameMatches.count) accounts\n", stderr)
        exit(1)
    } else {
        matchedIDs = idPrefixMatches
    }

    if matchedIDs.isEmpty {
        fputs("Account '\(filter)' not found in config\n", stderr)
        exit(1)
    }
    let matchedSet = Set(matchedIDs.map { $0.lowercased() })
    matchedAccountIDSetForFilter = matchedSet
    snapshots = snapshots.filter { matchedSet.contains($0.accountId.uuidString.lowercased()) }
}

// MARK: – --since filter (task 81)
if let since = sinceDate {
    snapshots = snapshots.filter { $0.timestamp >= since }
}

// default TUI config
let tuiConfig = TUIConfig(
    layout: ["input_tokens","output_tokens","cache_tokens","cost_usd","last_updated","model_breakdown"],
    colorScheme: "default",
    showLogo: true,
    separatorChar: "─",
    labelWidth: 18
)

func isCumulativeSnapshot(_ snapshot: UsageSnapshot) -> Bool {
    let model = snapshot.modelBreakdown.first?.modelId ?? ""
    let cumulativeModels: Set<String> = [
        "claude-code-local",
        "claude-ai-web",
        "codex-local",
        "gemini-local",
        "openai-org",
        "windsurf-enterprise",
        "copilot-metrics",
    ]
    return cumulativeModels.contains(model)
}

func normalizeDailySnapshots(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
    var eventSnapshots: [UsageSnapshot] = []
    var cumulativeSnapshots: [UsageSnapshot] = []
    for snapshot in snapshots {
        if isCumulativeSnapshot(snapshot) {
            cumulativeSnapshots.append(snapshot)
        } else {
            eventSnapshots.append(snapshot)
        }
    }
    if let latestCumulative = cumulativeSnapshots.max(by: { $0.timestamp < $1.timestamp }) {
        eventSnapshots.append(latestCumulative)
    }
    return eventSnapshots
}

func normalizeByAccountWithinDay(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
    Dictionary(grouping: snapshots, by: \.accountId).values.flatMap { normalizeDailySnapshots($0) }
}

// MARK: – Output

if formatJSON && !showForecast && !showModels && !showOptimizerHints {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = .prettyPrinted
    if let out = try? enc.encode(snapshots) {
        print(String(data: out, encoding: .utf8)!)
    }
    exit(0)
}

// MARK: – --models (task 80)
if showModels {
    let byModel = Dictionary(grouping: snapshots.flatMap { $0.modelBreakdown }, by: { $0.modelId })
    let rows = byModel.map { (id, us) in
        (id, us.reduce(0) { $0 + $1.inputTokens }, us.reduce(0) { $0 + $1.outputTokens }, us.reduce(0) { $0 + $1.costUSD })
    }.sorted { $0.3 > $1.3 }
    if formatJSON {
        let obj = rows.map { ["model": $0.0, "input_tokens": $0.1, "output_tokens": $0.2, "cost_usd": $0.3] as [String: Any] }
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
           let s = String(data: d, encoding: .utf8) { print(s) }
    } else {
        print("\(pad("Model", width: 40)) | \(pad("Input Tokens", width: 12)) | \(pad("Output Tokens", width: 12)) | Cost USD")
        print(String(repeating: "─", count: 80))
        for (id, inp, out2, cost) in rows {
            print("\(pad(id, width: 40)) | \(pad("\(inp)", width: 12)) | \(pad("\(out2)", width: 12)) | \(String(format: "$%.4f", cost))")
        }
    }
    exit(0)
}

if showOptimizerHints {
    let hintsFile = sharedContainer.appendingPathComponent("model_hints.json")
    guard let data = try? Data(contentsOf: hintsFile),
          let decodedHints = try? decoder.decode([ModelHintPayload].self, from: data) else {
        if formatJSON {
            print("[]")
        } else {
            print("No optimizer hints available.")
        }
        exit(0)
    }
    let hints = matchedAccountIDSetForFilter.map { matched in
        decodedHints.filter { matched.contains($0.accountId.uuidString.lowercased()) }
    } ?? decodedHints

    let accountNameByID: [String: String] = {
        guard let obj = loadConfigJSONObject(from: configFile),
              let accounts = obj["accounts"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for row in accounts {
            guard let id = row["id"] as? String else { continue }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out[id.lowercased()] = name.isEmpty ? id : name
        }
        return out
    }()

    if formatJSON {
        let rows: [[String: Any]] = hints.map { hint in
            let accountID = hint.accountId.uuidString.lowercased()
            return [
                "account_id": hint.accountId.uuidString,
                "account_name": accountNameByID[accountID] ?? hint.accountId.uuidString,
                "provider": providerName(forRecommendedModel: hint.recommendedModel),
                "recommended_model": hint.recommendedModel,
                "estimated_savings_usd": hint.estimatedSavingsUSD,
                "expensive_model_tokens": hint.expensiveModelTokens,
                "confidence": confidenceLabel(hint.savingsConfidence),
                "generated_at": ISO8601DateFormatter().string(from: hint.date),
            ]
        }
        if let out = try? JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted),
           let s = String(data: out, encoding: .utf8) {
            print(s)
        } else {
            print("[]")
        }
    } else {
        print("\(pad("Account", width: 24)) | \(pad("Provider", width: 14)) | \(pad("Confidence", width: 10)) | \(pad("Recommended", width: 20)) | Savings")
        print(String(repeating: "─", count: 96))
        for hint in hints.sorted(by: { $0.estimatedSavingsUSD > $1.estimatedSavingsUSD }) {
            let accountID = hint.accountId.uuidString.lowercased()
            let accountName = accountNameByID[accountID] ?? hint.accountId.uuidString
            let provider = providerName(forRecommendedModel: hint.recommendedModel)
            let confidence = confidenceLabel(hint.savingsConfidence)
            print(
                "\(pad(accountName, width: 24)) | \(pad(provider, width: 14)) | \(pad(confidence, width: 10)) | \(pad(hint.recommendedModel, width: 20)) | \(String(format: "$%.2f", hint.estimatedSavingsUSD))"
            )
        }
    }
    exit(0)
}

if showHistory {
    print(String(repeating: "─", count: 60))
    print("\(pad("Date", width: 12)) | \(pad("Cost", width: 8)) | \(pad("Input", width: 10)) | \(pad("Output", width: 10))")
    print(String(repeating: "─", count: 60))
    let cal = Calendar.current
    let grouped = Dictionary(grouping: snapshots) {
        cal.startOfDay(for: $0.timestamp)
    }
    for (day, snaps) in grouped.sorted(by: { $0.key < $1.key }) {
        let normalized = normalizeByAccountWithinDay(snaps)
        let cost = normalized.reduce(0) { $0 + $1.totalCostUSD }
        let inp = normalized.reduce(0) { $0 + $1.inputTokens }
        let out2 = normalized.reduce(0) { $0 + $1.outputTokens }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let costText = "$" + pad(String(format: "%.3f", cost), width: 7)
        print("\(pad(fmt.string(from: day), width: 12)) | \(costText) | \(pad("\(inp)", width: 10)) | \(pad("\(out2)", width: 10))")
    }
    exit(0)
}

if showHeatmap {
    guard !snapshots.isEmpty else { print("No data available"); exit(0) }
    print("Heatmap (7×24 average cost)")
    // 7 weekdays × 24 hours grid
    var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
    var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    let cal = Calendar.current
    let normalizedForHeatmap = Dictionary(grouping: snapshots) { cal.startOfDay(for: $0.timestamp) }
        .values
        .flatMap { normalizeByAccountWithinDay($0) }
    for snap in normalizedForHeatmap {
        let weekday = (cal.component(.weekday, from: snap.timestamp) - 1 + 6) % 7 // Mon=0
        let hour = cal.component(.hour, from: snap.timestamp)
        grid[weekday][hour] += snap.totalCostUSD
        counts[weekday][hour] += 1
    }
    let maxVal = grid.flatMap { $0 }.max() ?? 1
    let chars = ["░","▒","▓","█"]
    let days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
    for (wi, weekday) in grid.enumerated() {
        var row = "\(days[wi]) "
        for (_, val) in weekday.enumerated() {
            let norm = maxVal > 0 ? val / maxVal : 0
            let idx = min(chars.count - 1, Int(norm * Double(chars.count)))
            row += chars[idx]
        }
        print(row)
    }
    exit(0)
}

// default: render TUI
let todaySnaps = snapshots.filter {
    Calendar.current.isDateInToday($0.timestamp)
}
let renderer = TUIRenderer(snapshots: todaySnaps.isEmpty ? Array(snapshots.suffix(1)) : todaySnaps,
                            config: tuiConfig, noColor: noColor)
print(renderer.render())

if showForecast {
    guard !snapshots.isEmpty else { print("No data available"); exit(0) }
    if let fdata = try? Data(contentsOf: forecastFile),
       let forecasts = (try? decoder.decode(ForecastCachePayload.self, from: fdata).forecasts)
            ?? (try? decoder.decode([ForecastSnapshot].self, from: fdata)),
       let forecast = forecasts.first {
        if formatJSON { // task 83: --forecast --format json outputs valid JSON
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
            if let out = try? enc.encode(forecast) { print(String(data: out, encoding: .utf8)!) }
        } else {
            print(renderer.renderForecast(forecast))
        }
    } else {
        if formatJSON { print("{}") } else { print("No forecast data available.") }
    }
}

// MARK: – --watch N (task 82)
if let interval = watchInterval {
    signal(SIGINT) { _ in exit(0) }
    let selfURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let watchlessArgs = CLIArgumentUtils.removingWatchFlag(arguments: Array(CommandLine.arguments.dropFirst()))
    Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { _ in
        guard let lockFD = acquireWatchLock(watchLockFile) else { return }
        defer { releaseWatchLock(lockFD, url: watchLockFile) }
        let proc = Process(); proc.executableURL = selfURL; proc.arguments = watchlessArgs
        try? proc.run(); proc.waitUntilExit()
    }
    RunLoop.main.run() // blocks until SIGINT
}

exit(0)
