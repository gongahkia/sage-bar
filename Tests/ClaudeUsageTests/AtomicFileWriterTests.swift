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

    func testConcurrentWritesDoNotCrash() throws {
        let dest = tmpDir.appendingPathComponent("concurrent.bin")
        try AtomicFileWriter.write(Data("seed".utf8), to: dest)
        let iterations = 10
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "atomic-test", attributes: .concurrent)
        for i in 0..<iterations {
            group.enter()
            queue.async {
                defer { group.leave() }
                try? AtomicFileWriter.write(Data("write-\(i)".utf8), to: dest) // races expected
            }
        }
        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "concurrent writes should complete within timeout")
        let final = try Data(contentsOf: dest)
        XCTAssertFalse(final.isEmpty, "file must contain data")
        let leftovers = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        XCTAssertFalse(
            leftovers.contains { $0.pathExtension == "tmp" },
            "temporary files should be cleaned up after concurrent writes"
        )
    }

    func testEmptyDataWrite() throws {
        let dest = tmpDir.appendingPathComponent("empty.bin")
        try AtomicFileWriter.write(Data(), to: dest)
        let read = try Data(contentsOf: dest)
        XCTAssertTrue(read.isEmpty)
    }
}
