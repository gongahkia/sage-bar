import Foundation

enum PollingOrchestrator {
    static func pollAccounts(
        _ accountsToPoll: [Account],
        maxConcurrencyUpperCap: Int,
        fetchAccount: @escaping @Sendable (Account) async -> UUID?,
        jitterNanos: @escaping @Sendable (Account, Int) -> UInt64
    ) async -> [UUID] {
        let concurrencyLimit = min(max(1, accountsToPoll.count), maxConcurrencyUpperCap)
        let chunkSize = max(1, concurrencyLimit * 2)
        var updatedIDs: [UUID] = []
        var chunkStart = 0

        while chunkStart < accountsToPoll.count {
            guard !Task.isCancelled else { return updatedIDs }
            let chunkEnd = min(chunkStart + chunkSize, accountsToPoll.count)
            let chunk = Array(accountsToPoll[chunkStart ..< chunkEnd])
            await withTaskGroup(of: UUID?.self) { group in
                var launched = 0
                for account in chunk {
                    if launched >= concurrencyLimit {
                        _ = await group.next()
                    }
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let jitter = jitterNanos(account, accountsToPoll.count)
                        if jitter > 0 {
                            try? await Task.sleep(nanoseconds: jitter)
                        }
                        return await fetchAccount(account)
                    }
                    launched += 1
                }
                for await id in group {
                    if let id {
                        updatedIDs.append(id)
                    }
                }
            }
            chunkStart = chunkEnd
        }

        return updatedIDs
    }
}
