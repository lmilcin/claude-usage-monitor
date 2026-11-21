import Foundation

public enum UsageFormatting {
    /// Compact duration such as "2h 13m", "45m", "3d 4h" or "<1m".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded(.down))
        if minutes < 1 { return "<1m" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    /// "Resets in 2h 13m" for resets within a day, "Resets Thu 10:00 (in 3d 4h)" otherwise.
    public static func resetDescription(
        _ resetsAt: Date?,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let resetsAt else { return "No usage in this window yet" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "Resetting now" }
        if remaining < 24 * 3600 { return "Resets in \(duration(remaining))" }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return "Resets \(formatter.string(from: resetsAt)) (in \(duration(remaining)))"
    }

    /// "just now", "3 min ago", "2 h ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        return "\(duration(seconds)) ago"
    }
}
