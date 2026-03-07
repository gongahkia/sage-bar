import XCTest
@testable import SageBar

final class DateFormattersTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    // MARK: - ISO8601 internet date-time
    func testISO8601InternetDateTimeProducesValidString() {
        let str = SharedDateFormatters.iso8601InternetDateTime.string(from: referenceDate)
        XCTAssertFalse(str.isEmpty)
        XCTAssertTrue(str.contains("T"))
        XCTAssertTrue(str.hasSuffix("Z"))
    }

    func testISO8601InternetDateTimeRoundTrips() {
        let str = SharedDateFormatters.iso8601InternetDateTime.string(from: referenceDate)
        let parsed = SharedDateFormatters.iso8601InternetDateTime.date(from: str)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, referenceDate.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - ISO8601 with fractional seconds
    func testISO8601FractionalSecondsProducesValidString() {
        let str = SharedDateFormatters.iso8601InternetDateTimeFractional.string(from: referenceDate)
        XCTAssertFalse(str.isEmpty)
        XCTAssertTrue(str.contains("T"))
        XCTAssertTrue(str.contains("."))
    }

    func testISO8601FractionalSecondsRoundTrips() {
        let str = SharedDateFormatters.iso8601InternetDateTimeFractional.string(from: referenceDate)
        let parsed = SharedDateFormatters.iso8601InternetDateTimeFractional.date(from: str)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, referenceDate.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Full date
    func testFullDateFormatterRoundTrips() {
        let str = SharedDateFormatters.iso8601FullDate.string(from: referenceDate)
        XCTAssertFalse(str.isEmpty)
        let parsed = SharedDateFormatters.iso8601FullDate.date(from: str)
        XCTAssertNotNil(parsed)
        // full-date precision is day-level; verify same calendar day
        let cal = Calendar(identifier: .gregorian)
        let origComps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: referenceDate)
        let parsedComps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: parsed!)
        XCTAssertEqual(origComps.year, parsedComps.year)
        XCTAssertEqual(origComps.month, parsedComps.month)
        XCTAssertEqual(origComps.day, parsedComps.day)
    }

    // MARK: - Consistency (same input -> same output)
    func testFormattersAreConsistent() {
        let s1 = SharedDateFormatters.iso8601InternetDateTime.string(from: referenceDate)
        let s2 = SharedDateFormatters.iso8601InternetDateTime.string(from: referenceDate)
        XCTAssertEqual(s1, s2)
        let f1 = SharedDateFormatters.iso8601InternetDateTimeFractional.string(from: referenceDate)
        let f2 = SharedDateFormatters.iso8601InternetDateTimeFractional.string(from: referenceDate)
        XCTAssertEqual(f1, f2)
        let d1 = SharedDateFormatters.iso8601FullDate.string(from: referenceDate)
        let d2 = SharedDateFormatters.iso8601FullDate.string(from: referenceDate)
        XCTAssertEqual(d1, d2)
    }
}
