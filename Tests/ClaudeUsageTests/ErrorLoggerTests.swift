import XCTest
@testable import SageBar

final class ErrorLoggerTests: XCTestCase {
    private var logURL: URL!
    private var logger: ErrorLogger!

    override func setUp() {
        super.setUp()
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("errors_test_\(UUID().uuidString).log")
        logger = ErrorLogger(logFile: logURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logURL)
        super.tearDown()
    }

    // MARK: - Task 85: 1MB rotation keeps last 500 lines

    func testLogRotationAt1MB() {
        // write 1050 lines of ~1100 bytes each → exceeds 1MB
        let line = String(repeating: "x", count: 1050) + "\n"
        for _ in 0..<1050 {
            logger.log(line, level: "ERROR")
        }
        let exp = expectation(description: "rotation complete")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { exp.fulfill() }
        wait(for: [exp], timeout: 5)
        let lines = logger.readLast(600)
        XCTAssertLessThanOrEqual(lines.count, 501, // 500 kept + optional rotation INFO line
            "log rotation must keep at most 500 lines + rotation note")
    }

    // MARK: - Task 86: clearLog() → 0-byte file

    func testClearLogResultsInEmptyFile() {
        logger.log("some error", level: "ERROR")
        let writeExp = expectation(description: "write done")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { writeExp.fulfill() }
        wait(for: [writeExp], timeout: 2)
        logger.clearLog()
        let clearExp = expectation(description: "clear done")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { clearExp.fulfill() }
        wait(for: [clearExp], timeout: 2)
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int ?? -1
        XCTAssertEqual(size, 0, "errors.log must be 0 bytes after clearLog()")
    }

    func testEmittedLogLineMatchesContract() {
        logger.log("contract check", level: "WARN", file: "/tmp/Foo.swift", line: 42)
        let exp = expectation(description: "write done")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        guard let loggedLine = logger.readLast(1).first else {
            XCTFail("expected one log line")
            return
        }
        assertValidErrorLogLine(loggedLine)
    }
}
