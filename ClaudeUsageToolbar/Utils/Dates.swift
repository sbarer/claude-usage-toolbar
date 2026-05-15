import Foundation

enum DateUtils {
    // "h:mma, MMM d" — reset times in tooltips and logs
    static let resetTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma, MMM d"
        return f
    }()

    // "h:mma" with lowercase am/pm — log file timestamps
    static let logTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    // Full date + short time — weekly alert absolute date
    static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    static let iso = ISO8601DateFormatter()

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Parse ISO 8601 date from a JSON value, with or without fractional seconds.
    static func parseISO(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }

    // Format a date as "h:mma, MMM d" (e.g. "3:45pm, May 15").
    static func formatReset(_ date: Date) -> String {
        resetTimeFormatter.string(from: date)
    }

    // Compact H:MM or 0:MM countdown for the menu bar label.
    static func formatBarCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return String(format: "%d:%02d", h, m) }
        return String(format: "0:%02d", m)
    }

    // Verbose countdown for menu items (e.g. "1h05m30s", "5m30s", "45s").
    static func formatMenuCountdown(_ seconds: TimeInterval, showSeconds: Bool = true) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return showSeconds ? String(format: "%dh%02dm%02ds", h, m, s) : String(format: "%dh%02dm", h, m)
        }
        if m > 0 { return showSeconds ? String(format: "%dm%02ds", m, s) : String(format: "%dm", m) }
        return showSeconds ? "\(s)s" : "0m"
    }

    // Elapsed time as "Xs ago", "Xm Xs ago", or "Xh Xm ago".
    static func formatAgo(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m \(s % 60)s ago" }
        return "\(m / 60)h \(m % 60)m ago"
    }

    // Rate limit retry interval formatted as "Xm:XXs".
    static func formatRetryInterval(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        return String(format: "%dm%02ds", total / 60, total % 60)
    }

    // Natural language time remaining to a future date.
    static func relativeDescription(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "any moment now" }
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if days >= 1 { return "in \(days)d \(hours)h" }
        if hours >= 1 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }
}
