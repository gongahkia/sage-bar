import XCTest
@testable import SageBar

final class ParserMetricsStoreTests: XCTestCase {
    private var store: ParserMetricsStore!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parser_metrics_test_\(UUID().uuidString).json")
        store = ParserMetricsStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func drainQueue() {
        let exp = expectation(description: "drain")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testRecordAndRetrieveMetrics() {
        store.record(parser: "testParser", filesScanned: 10, linesParsed: 200,
                     linesRejected: 5, bytesRead: 4096, cpuTimeMs: 12, wallTimeMs: 15)
        drainQueue()
        let snapshots = store.snapshot()
        XCTAssertEqual(snapshots.count, 1)
        let s = snapshots[0]
        XCTAssertEqual(s.parser, "testParser")
        XCTAssertEqual(s.runs, 1)
        XCTAssertEqual(s.filesScanned, 10)
        XCTAssertEqual(s.linesParsed, 200)
        XCTAssertEqual(s.linesRejected, 5)
        XCTAssertEqual(s.bytesRead, 4096)
        XCTAssertEqual(s.cpuTimeMs, 12)
        XCTAssertEqual(s.wallTimeMs, 15)
    }

    func testMetricsPersistAcrossReads() {
        store.record(parser: "p1", filesScanned: 1, linesParsed: 10,
                     linesRejected: 0, bytesRead: 100, cpuTimeMs: 1, wallTimeMs: 2)
        drainQueue()
        store.record(parser: "p1", filesScanned: 2, linesParsed: 20,
                     linesRejected: 1, bytesRead: 200, cpuTimeMs: 3, wallTimeMs: 4)
        drainQueue()
        let snapshots = store.snapshot()
        XCTAssertEqual(snapshots.count, 1)
        let s = snapshots[0]
        XCTAssertEqual(s.runs, 2)
        XCTAssertEqual(s.filesScanned, 3)
        XCTAssertEqual(s.linesParsed, 30)
        XCTAssertEqual(s.linesRejected, 1)
        XCTAssertEqual(s.bytesRead, 300)
        XCTAssertEqual(s.cpuTimeMs, 4)
        XCTAssertEqual(s.wallTimeMs, 6)
        // re-create store from same file to verify persistence
        let store2 = ParserMetricsStore(fileURL: fileURL)
        let snapshots2 = store2.snapshot()
        XCTAssertEqual(snapshots2.count, 1)
        XCTAssertEqual(snapshots2[0].runs, 2)
    }
}
