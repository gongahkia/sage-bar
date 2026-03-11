import Foundation

private final class AtomicFileWriteCoordinator {
    static let shared = AtomicFileWriteCoordinator()

    private var locksByPath: [String: NSLock] = [:]
    private let registryLock = NSLock()

    func withExclusiveAccess<T>(to destination: URL, _ body: () throws -> T) rethrows -> T {
        let path = destination.standardizedFileURL.path
        let lock = lockForPath(path)
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func lockForPath(_ path: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }

        if let existing = locksByPath[path] {
            return existing
        }

        let created = NSLock()
        created.name = "AtomicFileWriter.\(path)"
        locksByPath[path] = created
        return created
    }
}

enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL) throws {
        try AtomicFileWriteCoordinator.shared.withExclusiveAccess(to: destination) {
            let fileManager = FileManager.default
            let directory = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let tmp = uniqueTemporaryURL(for: destination)
            defer { try? fileManager.removeItem(at: tmp) }

            fileManager.createFile(atPath: tmp.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: tmp) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? handle.close() }

            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: tmp)
            } else {
                do {
                    try fileManager.moveItem(at: tmp, to: destination)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: tmp)
                }
            }
        }
    }

    private static func uniqueTemporaryURL(for destination: URL) -> URL {
        let filename = ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        return destination.deletingLastPathComponent().appendingPathComponent(filename)
    }
}
