import Foundation

// MARK: – Shared container path (mirrors AppConstants)
let appGroup = "group.dev.claudeusage"
let sharedContainer: URL = {
    if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
        return url
    }
    return FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage")
}()
let cacheFile = sharedContainer.appendingPathComponent("usage_cache.json")
let forecastFile = sharedContainer.appendingPathComponent("forecast_cache.json")
let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-usage")
let configFile = configDir.appendingPathComponent("config.toml")

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
var sinceDate: Date? = nil
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
    case "--since":
        if let raw = iter.next() {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
            sinceDate = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }
    case "--watch":
        if let raw = iter.next(), let n = Int(raw) { watchInterval = n } else { watchInterval = 30 }
    case "--errors": showErrors = true
    case "--help":
        print("claude-usage [--account NAME] [--no-color] [--format json] [--forecast] [--history] [--heatmap] [--models] [--since DATE] [--watch N] [--config] [--errors[=N]] [--version]")
        exit(0)
    default:
        if arg.hasPrefix("--errors="), let n = Int(arg.dropFirst("--errors=".count)) {
            showErrors = true; errorsCount = n
        }
    }
}

// MARK: – --config

if showConfig {
    let cfgPath = configDir.appendingPathComponent("config.toml")
    if let raw = try? Data(contentsOf: cfgPath),
       var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
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

guard FileManager.default.fileExists(atPath: cacheFile.path),
      let data = try? Data(contentsOf: cacheFile) else {
    fputs("Run ClaudeUsage.app first to populate data\n", stderr)
    exit(1)
}

guard var snapshots = try? decoder.decode([UsageSnapshot].self, from: data) else {
    fputs("Parse error: cache file malformed\n", stderr)
    exit(2)
}

// filter by account name/id; validate filter against config accounts
if let filter = accountFilter {
    let cfgPath = configDir.appendingPathComponent("config.toml")
    var knownIds: [String] = []
    if let raw = try? Data(contentsOf: cfgPath),
       let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
       let accounts = obj["accounts"] as? [[String: Any]] {
        knownIds = accounts.compactMap { $0["id"] as? String }
    }
    let filterLow = filter.lowercased()
    let matched = knownIds.filter { $0.lowercased().hasPrefix(filterLow) }
    if matched.isEmpty {
        fputs("Account '\(filter)' not found in config\n", stderr)
        exit(1)
    }
    snapshots = snapshots.filter { matched.contains($0.accountId.uuidString) }
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

// MARK: – Output

if formatJSON && !showForecast && !showModels {
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
        print(String(format: "%-40s | %-12s | %-12s | %s", "Model", "Input Tokens", "Output Tokens", "Cost USD"))
        print(String(repeating: "─", count: 80))
        for (id, inp, out2, cost) in rows {
            print(String(format: "%-40s | %-12d | %-12d | $%.4f", id, inp, out2, cost))
        }
    }
    exit(0)
}

if showHistory {
    print(String(repeating: "─", count: 60))
    print(String(format: "%-12s | %-8s | %-10s | %-10s", "Date", "Cost", "Input", "Output"))
    print(String(repeating: "─", count: 60))
    let cal = Calendar.current
    let grouped = Dictionary(grouping: snapshots) {
        cal.startOfDay(for: $0.timestamp)
    }
    for (day, snaps) in grouped.sorted(by: { $0.key < $1.key }) {
        let cost = snaps.reduce(0) { $0 + $1.totalCostUSD }
        let inp = snaps.reduce(0) { $0 + $1.inputTokens }
        let out2 = snaps.reduce(0) { $0 + $1.outputTokens }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        print(String(format: "%-12s | $%-7.3f | %-10d | %-10d", fmt.string(from: day), cost, inp, out2))
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
    for snap in snapshots {
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
       let forecasts = try? decoder.decode([ForecastSnapshot].self, from: fdata),
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
    let watchlessArgs = Array(CommandLine.arguments.dropFirst()).filter { a in
        a != "--watch" && a != String(interval)
    }
    Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { _ in
        let proc = Process(); proc.executableURL = selfURL; proc.arguments = watchlessArgs
        try? proc.run(); proc.waitUntilExit()
    }
    RunLoop.main.run() // blocks until SIGINT
}

exit(0)
