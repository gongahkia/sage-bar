import XCTest

func assertValidErrorLogLine(
    _ line: String,
    file: StaticString = #filePath,
    lineNumber: UInt = #line
) {
    let pattern = #"^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:\-+Z]+\] \[(INFO|WARN|ERROR)\] [^:]+:[0-9]+ .+$"#
    let range = NSRange(location: 0, length: line.utf16.count)
    let regex = try? NSRegularExpression(pattern: pattern)
    let match = regex?.firstMatch(in: line, options: [], range: range)
    XCTAssertNotNil(match, "Invalid error log line format: \(line)", file: file, line: lineNumber)
}
