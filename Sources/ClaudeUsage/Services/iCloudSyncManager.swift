import Foundation
import Combine
import OSLog
import CryptoKit

private let log = Logger(subsystem: "dev.claudeusage", category: "iCloudSync")

enum SyncState {
    case disabled, idle, syncing, error(String)
    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .idle: return "Idle"
        case .syncing: return "Syncing…"
        case .error(let e): return "Error: \(e)"
        }
    }
}

class iCloudSyncManager: ObservableObject {
    private struct SyncEnvelope: Codable {
        var schemaVersion: Int
        var conflictEpoch: Int
        var lastWriterID: String
        var snapshots: [UsageSnapshot]
    }

    static let shared = iCloudSyncManager()
    @Published var syncState: SyncState = .disabled
    @Published var lastSyncDate: Date? = UserDefaults.standard.object(forKey: "lastCloudSyncDate") as? Date

    private var metadataQuery: NSMetadataQuery?
    private var metadataObserver: NSObjectProtocol?
    private let coordinator = NSFileCoordinator()
    private let coordTimeout: TimeInterval = 5
    private let lastSyncPayloadHashKey = "lastCloudSyncPayloadHash"
    private let syncConflictEpochKey = "iCloudSyncConflictEpoch"
    private let lastLocalCacheHashKey = "lastLocalCacheHash"

    private init() {}

    private func isICloudAvailable() -> Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    private func containerURL(config: iCloudSyncConfig) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: config.containerIdentifier)?
            .appendingPathComponent("usage_cache.json")
    }

    func syncNow() async {
        let config = ConfigManager.shared.load().iCloudSync
        guard config.enabled, !config.localOnly else { syncState = .disabled; return }
        guard isICloudAvailable() else {
            log.warning("iCloud not available — sync disabled")
            ErrorLogger.shared.log("iCloud not available — sync disabled", level: "WARN")
            syncState = .error("iCloud unavailable")
            return
        }
        log.info("iCloud sync started")
        syncState = .syncing
        defer {
            syncState = .idle
            lastSyncDate = Date()
            UserDefaults.standard.set(Date(), forKey: "lastCloudSyncDate")
            NotificationCenter.default.post(name: .iCloudSyncDidComplete, object: nil)
            log.info("iCloud sync completed")
        }
        guard let remoteURL = containerURL(config: config) else {
            syncState = .error("iCloud container unavailable"); return
        }
        let localSnaps = await CacheManager.shared.loadAsync()
        let localEncoder = JSONEncoder()
        localEncoder.dateEncodingStrategy = .iso8601
        if let localData = try? localEncoder.encode(UsageCachePayload(snapshots: localSnaps)) {
            let localHash = contentHash(for: localData)
            if UserDefaults.standard.string(forKey: lastLocalCacheHashKey) == localHash {
                log.debug("iCloud sync skipped: local cache hash unchanged")
                return
            }
            UserDefaults.standard.set(localHash, forKey: lastLocalCacheHashKey)
        }
        let remoteData = await coordinateRead(at: remoteURL)
        var remoteSnaps: [UsageSnapshot] = []
        var remoteConflictEpoch = 0
        if let data = remoteData {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let envelope = try? dec.decode(SyncEnvelope.self, from: data) {
                remoteSnaps = envelope.snapshots
                remoteConflictEpoch = envelope.conflictEpoch
            } else {
                remoteSnaps = (try? dec.decode(UsageCachePayload.self, from: data).snapshots)
                    ?? (try? dec.decode([UsageSnapshot].self, from: data))
                    ?? []
            }
        }
        let localEpoch = UserDefaults.standard.integer(forKey: syncConflictEpochKey)
        if remoteConflictEpoch > localEpoch && !remoteSnaps.isEmpty {
            ErrorLogger.shared.log("iCloud conflict detected: remote epoch \(remoteConflictEpoch) > local \(localEpoch); merging with remote-preferred", level: "WARN")
        }
        let merged = merge(local: localSnaps, remote: remoteSnaps)
        await CacheManager.shared.saveAsync(merged)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let nextConflictEpoch = max(localEpoch, remoteConflictEpoch) + 1
        let writerID = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let envelope = SyncEnvelope(
            schemaVersion: CacheSchema.currentVersion,
            conflictEpoch: nextConflictEpoch,
            lastWriterID: writerID,
            snapshots: merged
        )
        let data: Data
        do { data = try enc.encode(envelope) }
        catch {
            ErrorLogger.shared.log("iCloud sync envelope encode failed: \(error.localizedDescription)")
            return
        }
        let hash = contentHash(for: data)
        if UserDefaults.standard.string(forKey: lastSyncPayloadHashKey) == hash {
            log.debug("iCloud sync write skipped: payload hash unchanged")
            return
        }
        if await writeWithBackoff(data: data, to: remoteURL) {
            UserDefaults.standard.set(hash, forKey: lastSyncPayloadHashKey)
            UserDefaults.standard.set(nextConflictEpoch, forKey: syncConflictEpochKey)
        }
    }

    /// dedup by deterministic event key: accountId + timestamp + modelId + sourceType
    func merge(local: [UsageSnapshot], remote: [UsageSnapshot]) -> [UsageSnapshot] {
        var byKey: [String: UsageSnapshot] = [:]
        for snap in local + remote {
            let key = mergeKey(for: snap)
            if let existing = byKey[key] {
                byKey[key] = preferredSnapshot(existing, snap)
            } else {
                byKey[key] = snap
            }
        }
        return byKey.values.sorted { $0.timestamp < $1.timestamp }
    }

    func startMetadataQuery(config: iCloudSyncConfig) {
        stopMetadataQuery()
        guard config.enabled, !config.localOnly else { return }
        guard isICloudAvailable() else {
            ErrorLogger.shared.log("iCloud not available — sync disabled", level: "WARN")
            return
        }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "%K LIKE '*usage_cache.json'", NSMetadataItemFSNameKey)
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] _ in
            Task { await self?.syncNow() }
        }
        q.start()
        metadataQuery = q
    }

    func stopMetadataQuery() {
        if let observer = metadataObserver {
            NotificationCenter.default.removeObserver(observer)
            metadataObserver = nil
        }
        metadataQuery?.stop()
        metadataQuery = nil
    }

    // MARK: – Coordinator helpers with 5s timeout

    private func coordinateRead(at url: URL) async -> Data? {
        await Task.detached(priority: .utility) { [coordinator, coordTimeout] in
            let sem = DispatchSemaphore(value: 0)
            var result: Data? = nil
            DispatchQueue.global(qos: .utility).async {
                var err: NSError?
                coordinator.coordinate(readingItemAt: url, options: [], error: &err) { u in
                    do { result = try Data(contentsOf: u) }
                    catch { ErrorLogger.shared.log("iCloud read failed: \(error.localizedDescription)") }
                }
                if let e = err { ErrorLogger.shared.log("NSFileCoordinator read error: \(e.localizedDescription)") }
                sem.signal()
            }
            if sem.wait(timeout: .now() + coordTimeout) == .timedOut {
                ErrorLogger.shared.log("NSFileCoordinator read timed out for \(url.lastPathComponent)")
            }
            return result
        }.value
    }

    private func coordinateWrite(data: Data, to url: URL) async -> Bool {
        await Task.detached(priority: .utility) { [coordinator, coordTimeout] in
            let sem = DispatchSemaphore(value: 0)
            var success = false
            DispatchQueue.global(qos: .utility).async {
                var err: NSError?
                coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
                    do { try data.write(to: u, options: .atomic); success = true }
                    catch { ErrorLogger.shared.log("iCloud write failed: \(error.localizedDescription)") }
                }
                if let e = err { ErrorLogger.shared.log("NSFileCoordinator write error: \(e.localizedDescription)") }
                sem.signal()
            }
            if sem.wait(timeout: .now() + coordTimeout) == .timedOut {
                ErrorLogger.shared.log("NSFileCoordinator write timed out for \(url.lastPathComponent)")
            }
            return success
        }.value
    }

    private func writeWithBackoff(data: Data, to url: URL) async -> Bool {
        let delays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000] // 1s, 2s, 4s
        for (i, delay) in delays.enumerated() {
            if await coordinateWrite(data: data, to: url) { return true }
            if i < delays.count - 1 {
                try? await Task.sleep(nanoseconds: delay)
            } else {
                ErrorLogger.shared.log("iCloud sync write failed after \(delays.count) retries")
            }
        }
        return false
    }

    internal func contentHash(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func mergeKey(for snapshot: UsageSnapshot) -> String {
        let modelId = snapshot.modelBreakdown.map(\.modelId).sorted().first ?? "unknown"
        let sourceType = sourceType(forModel: modelId)
        return "\(snapshot.accountId.uuidString)|\(snapshot.timestamp.ISO8601Format())|\(modelId)|\(sourceType)"
    }

    private func sourceType(forModel modelId: String) -> String {
        switch modelId {
        case "claude-code-local":
            return "claude-code"
        case "claude-ai-web":
            return "claude-ai-web"
        case "codex-local":
            return "codex-local"
        case "gemini-local":
            return "gemini-local"
        case "openai-org":
            return "openai-org"
        case "windsurf-enterprise":
            return "windsurf-enterprise"
        case "copilot-metrics":
            return "copilot-metrics"
        default:
            if modelId.hasPrefix("gemini-") {
                return "gemini-local"
            }
            if modelId.hasPrefix("claude-") {
                return "anthropic"
            }
            if modelId.hasPrefix("copilot-") {
                return "copilot-metrics"
            }
            return "unknown"
        }
    }

    private func preferredSnapshot(_ lhs: UsageSnapshot, _ rhs: UsageSnapshot) -> UsageSnapshot {
        let lhsTokens = lhs.inputTokens + lhs.outputTokens + lhs.cacheCreationTokens + lhs.cacheReadTokens
        let rhsTokens = rhs.inputTokens + rhs.outputTokens + rhs.cacheCreationTokens + rhs.cacheReadTokens
        let lhsScore = (
            lhs.costConfidence == .billingGrade ? 1 : 0,
            lhs.isStale ? 0 : 1,
            lhsTokens,
            lhs.totalCostUSD,
            lhs.timestamp.timeIntervalSince1970
        )
        let rhsScore = (
            rhs.costConfidence == .billingGrade ? 1 : 0,
            rhs.isStale ? 0 : 1,
            rhsTokens,
            rhs.totalCostUSD,
            rhs.timestamp.timeIntervalSince1970
        )
        return rhsScore > lhsScore ? rhs : lhs
    }
}

extension Notification.Name {
    static let iCloudSyncDidComplete = Notification.Name("iCloudSyncDidComplete")
}
