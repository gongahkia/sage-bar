import Foundation

enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tmp = destination.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }

        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
    }
}
