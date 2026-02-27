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

// MARK: – Arg parsing

var accountFilter: String? = nil
var noColor = false
var formatJSON = false
var showForecast = false
var showHistory = false
var showHeatmap = false

var args = CommandLine.arguments.dropFirst()
var iter = args.makeIterator()
while let arg = iter.next() {
    switch arg {
    case "--account": accountFilter = iter.next()
    case "--no-color": noColor = true
    case "--format":
        if iter.next() == "json" { formatJSON = true }
    case "--forecast": showForecast = true
    case "--history": showHistory = true
    case "--heatmap": showHeatmap = true
    case "--help":
        print("claude-usage [--account NAME] [--no-color] [--format json] [--forecast] [--history] [--heatmap]")
        exit(0)
    default: break
    }
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

// filter by account name (match by id stored in snapshot; account filter by name requires config lookup)
if let filter = accountFilter {
    snapshots = snapshots.filter { $0.accountId.uuidString.lowercased().hasPrefix(filter.lowercased()) }
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

if formatJSON {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = .prettyPrinted
    if let out = try? enc.encode(snapshots) {
        print(String(data: out, encoding: .utf8)!)
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
    if let fdata = try? Data(contentsOf: forecastFile),
       let forecasts = try? decoder.decode([ForecastSnapshot].self, from: fdata),
       let forecast = forecasts.first {
        print(renderer.renderForecast(forecast))
    } else {
        print("No forecast data available.")
    }
}

exit(0)
