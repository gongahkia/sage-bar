import XCTest
@testable import SageBar

final class RetryPolicyTests: XCTestCase {
    private let base: UInt64 = 1_000_000_000 // 1s in nanos

    func testExponentialBackoffIncreasesWithAttempt() {
        let d0 = RetryPolicy.delayNanos(attempt: 0, retryAfterSeconds: nil, baseDelayNanos: base, maxExponent: 10, jitterFraction: 0)
        let d1 = RetryPolicy.delayNanos(attempt: 1, retryAfterSeconds: nil, baseDelayNanos: base, maxExponent: 10, jitterFraction: 0)
        let d2 = RetryPolicy.delayNanos(attempt: 2, retryAfterSeconds: nil, baseDelayNanos: base, maxExponent: 10, jitterFraction: 0)
        XCTAssertEqual(d0, base)
        XCTAssertEqual(d1, base * 2)
        XCTAssertEqual(d2, base * 4)
    }

    func testRetryAfterSecondsOverridesComputedDelay() {
        let delay = RetryPolicy.delayNanos(attempt: 0, retryAfterSeconds: 10, baseDelayNanos: base, maxExponent: 10, jitterFraction: 0)
        XCTAssertEqual(delay, 10_000_000_000, "retryAfterSeconds=10 should yield 10s in nanos")
    }

    func testJitterDoesNotExceedFraction() {
        let fraction = 0.25
        for _ in 0..<200 {
            let delay = RetryPolicy.delayNanos(attempt: 3, retryAfterSeconds: nil, baseDelayNanos: base, maxExponent: 10, jitterFraction: fraction)
            let baseValue = Double(base) * pow(2.0, 3.0)
            let maxAllowed = UInt64(baseValue + baseValue * fraction)
            XCTAssertGreaterThanOrEqual(delay, UInt64(baseValue))
            XCTAssertLessThanOrEqual(delay, maxAllowed)
        }
    }

    func testMaxExponentCapsBackoff() {
        let capped = RetryPolicy.delayNanos(attempt: 100, retryAfterSeconds: nil, baseDelayNanos: base, maxExponent: 3, jitterFraction: 0)
        let expected = UInt64(Double(base) * pow(2.0, 3.0))
        XCTAssertEqual(capped, expected, "attempt beyond maxExponent should cap at 2^maxExponent * base")
    }

    func testZeroAttemptReturnsBaseDelayWithinJitter() {
        let fraction = 0.1
        for _ in 0..<100 {
            let delay = RetryPolicy.delayNanos(attempt: 0, retryAfterSeconds: nil, baseDelayNanos: base, maxExponent: 10, jitterFraction: fraction)
            XCTAssertGreaterThanOrEqual(delay, base)
            XCTAssertLessThanOrEqual(delay, UInt64(Double(base) * (1.0 + fraction)))
        }
    }
}
