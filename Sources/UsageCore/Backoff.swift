import Foundation

/// Spaces out automatic refreshes after the server signals it is overloaded or throttling us
/// (HTTP 429, 5xx, a Cloudflare challenge). Each consecutive failure doubles the wait, starting
/// at twice the refresh interval, up to `maxDelay`. A server-sent `Retry-After` is honoured if it
/// asks for longer. Any successful fetch resets it.
public struct RefreshBackoff: Equatable, Sendable {
    public static let maxDelay: TimeInterval = 3600

    public private(set) var failures = 0
    /// Automatic refreshes are skipped until this moment.
    public private(set) var nextAttempt: Date?

    public init() {}

    /// Records one more throttled attempt and returns when the next automatic one may run.
    @discardableResult
    public mutating func recordFailure(
        at now: Date, refreshInterval: TimeInterval, retryAfter: TimeInterval? = nil
    ) -> Date {
        failures += 1
        let exponential = refreshInterval * pow(2, Double(min(failures, 16)))
        let delay = min(Self.maxDelay, max(exponential, retryAfter ?? 0))
        let next = now.addingTimeInterval(delay)
        nextAttempt = next
        return next
    }

    public mutating func reset() {
        failures = 0
        nextAttempt = nil
    }

    public func allowsAttempt(at now: Date) -> Bool {
        guard let nextAttempt else { return true }
        return now >= nextAttempt
    }
}

public enum RetryAfter {
    /// Parses an HTTP `Retry-After` value: either delay-seconds ("120") or an HTTP date
    /// ("Wed, 21 Oct 2015 07:28:00 GMT"). Returns the wait in seconds, never negative.
    public static func parse(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return TimeInterval(max(0, seconds)) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
