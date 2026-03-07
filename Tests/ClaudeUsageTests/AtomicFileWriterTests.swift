import XCTest
@testable import SageBar

final class AtomicFileWriterTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicFileWriterTests_\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testWriteNewFileSucceedsAndContentMatches() throws {
        let dest = tmpDir.appendingPathComponent("a.bin")
        let payload = Data("hello atomic".utf8)
        try AtomicFileWriter.write(payload, to: dest)
        let read = try Data(contentsOf: dest)
        XCTAssertEqual(read, payload)
    }

    func testWriteExistingFileReplacesContentAtomically() throws {
        let dest = tmpDir.appendingPathComponent("b.bin")
        try AtomicFileWriter.write(Data("old".utf8), to: dest)
        let updated = Data("new-content".utf8)
        try AtomicFileWriter.write(updated, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), updated)
        let tmpFile = dest.appendingPathExtension("tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpFile.path), "temp file should be cleaned up")
    }

    func testWriteToNonexistentDirectoryCreatesIt() throws {
        let dest = tmpDir
            .appendingPathComponent("nested/deep/dir")
            .appendingPathComponent("c.bin")
        let payload = Data("deep".utf8)
        try AtomicFileWriter.write(payload, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testConcurrentWritesDoNotCorrupt() throws {
        let dest = tmpDir.appendingPathComponent("concurrent.bin")
        try AtomicFileWriter.write(Data("seed".utf8), to: dest)
        let iterations = 50
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "atomic-test", attributes: .concurrent)
        var errors: [Error] = []
        let lock = NSLock()
        for i in 0..<iterations {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try AtomicFileWriter.write(Data("write-\(i)".utf8), to: dest)
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
            }
        }
        group.wait()
        XCTAssert(errors.isEmpty, "concurrent writes produced errors: \(errors)")
        let final = try Data(contentsOf: dest)
        XCTAssertFalse(final.isEmpty, "file must contain data from one of the writes")
        let text = String(data: final, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("write-"), "final content should be a complete write, got: \(text)")
    }

    func testEmptyDataWrite() throws {
        let dest = tmpDir.appendingPathComponent("empty.bin")
        try AtomicFileWriter.write(Data(), to: dest)
        let read = try Data(contentsOf: dest)
        XCTAssertTrue(read.isEmpty)
    }
}
