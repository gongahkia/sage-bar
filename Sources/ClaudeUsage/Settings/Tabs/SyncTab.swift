import SwiftUI

// MARK: – Sync Tab

struct SyncTab: View {
    @State private var config = ConfigManager.shared.load()
    @StateObject private var syncMgr = iCloudSyncManager.shared

    var body: some View {
        Form {
            if config.iCloudSync.enabled {
                Toggle("Enable iCloud sync", isOn: $config.iCloudSync.enabled)
                Toggle("Local only", isOn: $config.iCloudSync.localOnly)
                Text("Last sync: \(syncMgr.lastSyncDate.map { $0.formatted() } ?? "Never")").font(.caption)
                Text(syncMgr.syncState.label).font(.caption).foregroundColor(.secondary)
                Button("Sync Now") { Task { await iCloudSyncManager.shared.syncNow() } }
            } else {
                Toggle("Enable iCloud sync", isOn: $config.iCloudSync.enabled)
                Text("iCloud sync is off — data stays local only").foregroundColor(.secondary).font(.caption)
                Text("Requires iCloud Drive").foregroundColor(.secondary).font(.caption)
            }
        }
        .onChange(of: config.iCloudSync) { _ in ConfigManager.shared.save(config) }
        .padding()
    }
}

