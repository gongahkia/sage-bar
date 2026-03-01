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

enum ConfigSaveError: Error, CustomStringConvertible {
    case validationFailed(String)
    case directoryCreateFailed(String)
    case encodeFailed(String)
    case serializeFailed(String)
    case writeFailed(String)
    case replaceFailed(String)

    var description: String {
        switch self {
        case .validationFailed(let detail): return "validationFailed: \(detail)"
        case .directoryCreateFailed(let detail): return "directoryCreateFailed: \(detail)"
        case .encodeFailed(let detail): return "encodeFailed: \(detail)"
        case .serializeFailed(let detail): return "serializeFailed: \(detail)"
        case .writeFailed(let detail): return "writeFailed: \(detail)"
        case .replaceFailed(let detail): return "replaceFailed: \(detail)"
        }
    }
}

class ConfigManager {
    static let shared = ConfigManager()
    private let configDir: URL
    private let configFile: URL
    private let latestConfigSchemaVersion = 3
    private(set) var lastLoadError: ConfigLoadError?

    init(configDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-usage")) {
        self.configDir = configDir
        self.configFile = configDir.appendingPathComponent("config.toml")
    }

    func load() -> Config {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: configFile.path) else {
                return migrateAndNormalize(.default)
            }
            let raw: String
            do {
                raw = try String(contentsOf: configFile, encoding: .utf8)
            } catch {
                emitLoadError(.fileReadFailed(error.localizedDescription))
                return migrateAndNormalize(.default)
            }
            if let rawData = raw.data(using: .utf8),
               !rawData.isEmpty {
                do {
                    let decoded = try JSONDecoder().decode(Config.self, from: rawData)
                    lastLoadError = nil
                    return migrateAndNormalize(decoded)
                } catch {
                    emitLoadError(.jsonDecodeFailed(error.localizedDescription))
                }
            }
            let table: TOMLTable
            do {
                table = try TOMLTable(string: raw)
            } catch {
                emitLoadError(.tomlParseFailed(error.localizedDescription))
                return migrateAndNormalize(.default)
            }
            let json = table.convert(to: .json)
            guard let data = json.data(using: .utf8) else { return migrateAndNormalize(.default) }
            let decoded: Config
            do {
                decoded = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                emitLoadError(.tomlDecodeFailed(error.localizedDescription))
                return migrateAndNormalize(.default)
            }
            lastLoadError = nil
            return migrateAndNormalize(decoded)
        } catch {
            emitLoadError(.fileReadFailed(error.localizedDescription))
            return migrateAndNormalize(.default)
        }
    }

    @discardableResult
    func save(_ config: Config) -> Result<Void, ConfigSaveError> {
        let normalizedConfig = migrateAndNormalize(config)
        if let validationError = validate(normalizedConfig).first {
            let saveError = ConfigSaveError.validationFailed(validationError)
            ErrorLogger.shared.log("Config save error: \(saveError)")
            return .failure(saveError)
        }
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        } catch {
            let saveError = ConfigSaveError.directoryCreateFailed(error.localizedDescription)
            ErrorLogger.shared.log("Config save error: \(saveError)")
            return .failure(saveError)
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(normalizedConfig)
        } catch {
            let saveError = ConfigSaveError.encodeFailed(error.localizedDescription)
            ErrorLogger.shared.log("Config save error: \(saveError)")
            return .failure(saveError)
        }

        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            let saveError = ConfigSaveError.serializeFailed(error.localizedDescription)
            ErrorLogger.shared.log("Config save error: \(saveError)")
            return .failure(saveError)
        }

        let jsonData: Data
        do {
            // write as JSON-backed config (TOML serialisation deferred; JSON is a TOML superset)
            jsonData = try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
        } catch {
            let saveError = ConfigSaveError.serializeFailed(error.localizedDescription)
            ErrorLogger.shared.log("Config save error: \(saveError)")
            return .failure(saveError)
        }

        do {
            try AtomicFileWriter.write(jsonData, to: configFile)
            return .success(())
        } catch {
            let saveError = ConfigSaveError.writeFailed(error.localizedDescription)
            ErrorLogger.shared.log("Config save error: \(saveError)")
            return .failure(saveError)
        }
    }

    private func migrateAndNormalize(_ config: Config) -> Config {
        let migrated = migrate(config)
        return normalize(migrated)
    }

    private func migrate(_ config: Config) -> Config {
        var migrated = config
        if migrated.schemaVersion < 2 {
            // schema v2 introduces explicit config schemaVersion persistence
            migrated.schemaVersion = 2
        }
        if migrated.schemaVersion < 3 {
            // schema v3 preserves existing non-core providers as experimental metadata
            // by ensuring their controls remain visible in provider selection UI.
            if migrated.accounts.contains(where: { !$0.type.isCoreProvider }) {
                migrated.display.showExperimentalProviders = true
            }
            migrated.schemaVersion = 3
        }
        return migrated
    }

    private func normalize(_ config: Config) -> Config {
        var normalized = config
        normalized.schemaVersion = latestConfigSchemaVersion
        normalized.accounts.sort {
            if $0.order == $1.order {
                return $0.createdAt < $1.createdAt
            }
            return $0.order < $1.order
        }
        return normalized
    }

    func validate(_ config: Config) -> [String] {
        var issues: [String] = []
        if !(5...86_400).contains(config.pollIntervalSeconds) {
            issues.append("pollIntervalSeconds must be between 5 and 86400")
        }
        let validMenubarStyles: Set<String> = ["icon", "tokens", "cost"]
        if !validMenubarStyles.contains(config.display.menubarStyle) {
            issues.append("display.menubarStyle must be one of: icon, tokens, cost")
        }
        let validSparklineStyles: Set<String> = ["cost", "tokens"]
        if !validSparklineStyles.contains(config.sparkline.style) {
            issues.append("sparkline.style must be one of: cost, tokens")
        }
        let validWebhookEvents: Set<String> = ["threshold", "daily_digest", "weekly_summary"]
        if config.webhook.events.contains(where: { !validWebhookEvents.contains($0) }) {
            issues.append("webhook.events contains invalid event value")
        }
        return issues
    }

    private func emitLoadError(_ error: ConfigLoadError) {
        lastLoadError = error
        ErrorLogger.shared.log("Config load error: \(error)", level: "WARN")
    }
}
