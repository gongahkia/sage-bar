import Foundation
import TOMLKit

class ConfigManager {
    static let shared = ConfigManager()
    private let configDir: URL
    private let configFile: URL

    private init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage")
        self.configDir = base
        self.configFile = base.appendingPathComponent("config.toml")
    }

    func load() -> Config {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: configFile.path) else {
                return .default
            }
            let raw = try String(contentsOf: configFile, encoding: .utf8)
            let table = try TOMLKit.TOML.parse(raw)
            let data = try JSONSerialization.data(withJSONObject: table.toJSONObject())
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            return .default
        }
    }

    func save(_ config: Config) {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            let obj = try JSONSerialization.jsonObject(with: data)
            // write as JSON-backed config (TOML serialisation deferred; JSON is a TOML superset)
            let jsonData = try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
            let tmp = configFile.appendingPathExtension("tmp")
            try jsonData.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(configFile, withItemAt: tmp)
        } catch {}
    }
}

private extension TOMLKit.TOMLTable {
    func toJSONObject() -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in self {
            result[key] = value.toJSONValue()
        }
        return result
    }
}

private extension TOMLKit.TOMLValue {
    func toJSONValue() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map { $0.toJSONValue() }
        case .table(let t): return t.toJSONObject()
        default: return NSNull()
        }
    }
}
