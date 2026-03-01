import Foundation

enum RetryPolicy {
    static func delayNanos(
        attempt: Int,
        retryAfterSeconds: Int?,
        baseDelayNanos: UInt64,
        maxExponent: Int,
        jitterFraction: Double
    ) -> UInt64 {
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            let base = Double(retryAfterSeconds) * 1_000_000_000
            let jitter = Double.random(in: 0...(base * max(0, jitterFraction)))
            return UInt64(base + jitter)
        }
        let exponent = min(max(0, attempt), maxExponent)
        let base = Double(baseDelayNanos) * pow(2.0, Double(exponent))
        let jitter = Double.random(in: 0...(base * max(0, jitterFraction)))
        return UInt64(base + jitter)
    }
}
