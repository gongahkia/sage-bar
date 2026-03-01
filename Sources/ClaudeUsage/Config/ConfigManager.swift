import Foundation
import TOMLKit

enum ConfigLoadError: Error, CustomStringConvertible {
    case fileReadFailed(String)
    case jsonDecodeFailed(String)
    case tomlParseFailed(String)
    case tomlDecodeFailed(String)

    var description: String {
        switch self {
        case .fileReadFailed(let detail): return "fileReadFailed: \(detail)"
        case .jsonDecodeFailed(let detail): return "jsonDecodeFailed: \(detail)"
        case .tomlParseFailed(let detail): return "tomlParseFailed: \(detail)"
        case .tomlDecodeFailed(let detail): return "tomlDecodeFailed: \(detail)"
        }
    }
}

class ConfigManager {
    static let shared = ConfigManager()
    private let configDir: URL
    private let configFile: URL
    private(set) var lastLoadError: ConfigLoadError?

    init(configDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-usage")) {
        self.configDir = configDir
        self.configFile = configDir.appendingPathComponent("config.toml")
    }

    func load() -> Config {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: configFile.path) else {
                return normalize(.default)
            }
            let raw: String
            do {
                raw = try String(contentsOf: configFile, encoding: .utf8)
            } catch {
                emitLoadError(.fileReadFailed(error.localizedDescription))
                return normalize(.default)
            }
            if let rawData = raw.data(using: .utf8),
               !rawData.isEmpty {
                do {
                    let decoded = try JSONDecoder().decode(Config.self, from: rawData)
                    lastLoadError = nil
                    return normalize(decoded)
                } catch {
                    emitLoadError(.jsonDecodeFailed(error.localizedDescription))
                }
            }
            let table: TOMLTable
            do {
                table = try TOMLTable(string: raw)
            } catch {
                emitLoadError(.tomlParseFailed(error.localizedDescription))
                return normalize(.default)
            }
            let json = table.convert(to: .json)
            guard let data = json.data(using: .utf8) else { return normalize(.default) }
            let decoded: Config
            do {
                decoded = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                emitLoadError(.tomlDecodeFailed(error.localizedDescription))
                return normalize(.default)
            }
            lastLoadError = nil
            return normalize(decoded)
        } catch {
            emitLoadError(.fileReadFailed(error.localizedDescription))
            return normalize(.default)
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

    private func normalize(_ config: Config) -> Config {
        var normalized = config
        normalized.accounts.sort {
            if $0.order == $1.order {
                return $0.createdAt < $1.createdAt
            }
            return $0.order < $1.order
        }
        return normalized
    }

    private func emitLoadError(_ error: ConfigLoadError) {
        lastLoadError = error
        ErrorLogger.shared.log("Config load error: \(error)", level: "WARN")
    }
}
