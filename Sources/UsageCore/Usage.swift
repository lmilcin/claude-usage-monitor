import Foundation

/// One rate-limit window as reported by the usage endpoint
/// (e.g. `five_hour`, `seven_day`, `seven_day_opus`).
public struct UsageWindow: Equatable, Sendable {
    public let key: String
    /// Percentage of the limit already used, 0...100 (may exceed 100 in edge cases).
    public let utilization: Double
    public let resetsAt: Date?

    public init(key: String, utilization: Double, resetsAt: Date?) {
        self.key = key
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// Fraction of the limit still available, clamped to 0...1.
    public var remainingFraction: Double {
        min(1, max(0, (100 - utilization) / 100))
    }

    public var remainingPercent: Int { Int((remainingFraction * 100).rounded()) }
    public var usedPercent: Int { Int(min(100, max(0, utilization)).rounded()) }

    public var title: String { UsageWindow.title(forKey: key) }

    public static func title(forKey key: String) -> String {
        switch key {
        case "five_hour": return "Current session"
        case "seven_day": return "Weekly · all models"
        case "seven_day_opus": return "Weekly · Opus"
        case "seven_day_sonnet": return "Weekly · Sonnet"
        case "seven_day_oauth_apps": return "Weekly · OAuth apps"
        default:
            return key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    /// The 5-hour session window (`five_hour`).
    public let session: UsageWindow?
    /// The weekly all-models window (`seven_day`).
    public let weekly: UsageWindow?
    /// Any other windows reported (model-specific weekly limits, etc.), sorted by key.
    public let others: [UsageWindow]
    public let fetchedAt: Date

    public init(session: UsageWindow?, weekly: UsageWindow?, others: [UsageWindow], fetchedAt: Date) {
        self.session = session
        self.weekly = weekly
        self.others = others
        self.fetchedAt = fetchedAt
    }

    public var allWindows: [UsageWindow] {
        [session, weekly].compactMap { $0 } + others
    }
}

public enum UsageParseError: Error, Equatable, LocalizedError {
    case invalidJSON(String)
    case noUsageWindows

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): return "Unexpected response from server (\(detail))"
        case .noUsageWindows: return "Response contained no usage limits"
        }
    }
}

public enum UsageParser {
    /// Parses the JSON body of `GET /api/organizations/{id}/usage` (claude.ai) or
    /// `GET /api/oauth/usage` (api.anthropic.com). Both share the same shape:
    ///
    ///     { "five_hour": {"utilization": 12.0, "resets_at": "2025-11-04T04:59:59.943648+00:00"},
    ///       "seven_day": {...}, "seven_day_opus": null, "extra_usage": {...}, ... }
    ///
    /// Unknown keys are tolerated; any object with a numeric `utilization` is treated as a window.
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let raw: RawUsage
        do {
            raw = try JSONDecoder().decode(RawUsage.self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(80), as: UTF8.self)
            throw UsageParseError.invalidJSON(snippet.isEmpty ? "empty body" : snippet)
        }

        var windows: [String: UsageWindow] = [:]
        for (key, value) in raw.windows {
            guard let utilization = value.utilization else { continue }
            windows[key] = UsageWindow(
                key: key,
                utilization: utilization,
                resetsAt: value.resetsAt.flatMap(DateParsing.parseISO8601)
            )
        }
        guard !windows.isEmpty else { throw UsageParseError.noUsageWindows }

        let others = windows
            .filter { $0.key != "five_hour" && $0.key != "seven_day" }
            .map(\.value)
            .sorted { $0.key < $1.key }
        return UsageSnapshot(
            session: windows["five_hour"],
            weekly: windows["seven_day"],
            others: others,
            fetchedAt: now
        )
    }
}

// MARK: - Lenient decoding

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct RawWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try? c.decodeIfPresent(Double.self, forKey: .utilization)
        resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

private struct RawUsage: Decodable {
    let windows: [String: RawWindow]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var result: [String: RawWindow] = [:]
        for key in c.allKeys {
            // Values that are null, scalars or differently-shaped objects are skipped.
            if let window = try? c.decode(RawWindow.self, forKey: key) {
                result[key.stringValue] = window
            }
        }
        windows = result
    }
}

// MARK: - Dates

public enum DateParsing {
    /// Parses ISO-8601 timestamps with or without fractional seconds (any precision).
    public static func parseISO8601(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        // Strip fractional seconds (the API returns microseconds, which not every
        // ISO8601DateFormatter version accepts), then add them back manually.
        guard let dot = string.firstIndex(of: "."), dot > string.startIndex else { return nil }
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber { end = string.index(after: end) }
        let digits = string[string.index(after: dot)..<end]
        guard !digits.isEmpty else { return nil }
        let stripped = String(string[..<dot]) + String(string[end...])
        guard let base = plain.date(from: stripped) else { return nil }
        let fraction = Double("0." + digits) ?? 0
        return base.addingTimeInterval(fraction)
    }
}
