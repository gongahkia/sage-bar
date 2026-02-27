import Foundation
import Combine

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
    static let shared = iCloudSyncManager()
    @Published var syncState: SyncState = .disabled
    @Published var lastSyncDate: Date? = UserDefaults.standard.object(forKey: "lastCloudSyncDate") as? Date

    private var metadataQuery: NSMetadataQuery?
    private let coordinator = NSFileCoordinator()

    private init() {}

    private func containerURL(config: iCloudSyncConfig) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: config.containerIdentifier)?
            .appendingPathComponent("usage_cache.json")
    }

    func syncNow() async {
        let config = ConfigManager.shared.load().iCloudSync
        guard config.enabled, !config.localOnly else { syncState = .disabled; return }
        syncState = .syncing
        defer {
            syncState = .idle
            lastSyncDate = Date()
            UserDefaults.standard.set(Date(), forKey: "lastCloudSyncDate")
            NotificationCenter.default.post(name: .iCloudSyncDidComplete, object: nil)
        }
        guard let remoteURL = containerURL(config: config) else {
            syncState = .error("iCloud container unavailable"); return
        }
        let localSnaps = CacheManager.shared.load()
        var remoteSnaps: [UsageSnapshot] = []
        var coordErr: NSError?
        coordinator.coordinate(readingItemAt: remoteURL, options: [], error: &coordErr) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            remoteSnaps = (try? dec.decode([UsageSnapshot].self, from: data)) ?? []
        }
        let merged = merge(local: localSnaps, remote: remoteSnaps)
        CacheManager.shared.save(merged)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(merged) else { return }
        coordinator.coordinate(writingItemAt: remoteURL, options: .forReplacing, error: &coordErr) { url in
            try? data.write(to: url, options: .atomic)
        }
    }

    /// dedup by (accountId, timestamp within 1s), prefer higher total tokens
    func merge(local: [UsageSnapshot], remote: [UsageSnapshot]) -> [UsageSnapshot] {
        var result: [UsageSnapshot] = local
        for r in remote {
            let match = result.firstIndex(where: {
                $0.accountId == r.accountId && abs($0.timestamp.timeIntervalSince(r.timestamp)) < 1
            })
            if let i = match {
                let existing = result[i]
                let existingTotal = existing.inputTokens + existing.outputTokens
                let newTotal = r.inputTokens + r.outputTokens
                if newTotal > existingTotal { result[i] = r }
            } else {
                result.append(r)
            }
        }
        return result
    }

    func startMetadataQuery(config: iCloudSyncConfig) {
        guard config.enabled, !config.localOnly else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "%K LIKE '*usage_cache.json'", NSMetadataItemFSNameKey)
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] _ in
            Task { await self?.syncNow() }
        }
        q.start()
        metadataQuery = q
    }
}

extension Notification.Name {
    static let iCloudSyncDidComplete = Notification.Name("iCloudSyncDidComplete")
}
