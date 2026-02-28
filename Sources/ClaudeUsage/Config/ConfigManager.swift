import Foundation
import TOMLKit

class ConfigManager {
    static let shared = ConfigManager()
    private let configDir: URL
    private let configFile: URL

    init(configDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-usage")) {
        self.configDir = configDir
        self.configFile = configDir.appendingPathComponent("config.toml")
    }

    func load() -> Config {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: configFile.path) else {
                return .default
            }
            let raw = try String(contentsOf: configFile, encoding: .utf8)
            if let rawData = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(Config.self, from: rawData) {
                return decoded
            }
            let table = try TOMLTable(string: raw)
            let json = table.convert(to: .json)
            guard let data = json.data(using: .utf8) else { return .default }
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
