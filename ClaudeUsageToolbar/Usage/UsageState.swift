import Foundation

struct UsageState {
    enum Kind {
        case loading
        case ok(sessionPercent: Int, weeklyPercent: Int, weeklyResetsAt: Date?, sessionResetsAt: Date?)
        case unauthenticated
        case error(String)
    }
    let kind: Kind
    let apiTriesSinceLastSuccess: Int
    let rateLimitedUntil: Date?
    let rateLimitIsServerProvided: Bool
    let lastKnownSessionResetsAt: Date?
    let lastKnownWeeklyResetsAt: Date?
    let lastKnownSessionPercent: Int?
    let lastKnownWeeklyPercent: Int?

    init(
        kind: Kind,
        apiTriesSinceLastSuccess: Int = 0,
        rateLimitedUntil: Date? = nil,
        rateLimitIsServerProvided: Bool = false,
        lastKnownSessionResetsAt: Date? = nil,
        lastKnownWeeklyResetsAt: Date? = nil,
        lastKnownSessionPercent: Int? = nil,
        lastKnownWeeklyPercent: Int? = nil
    ) {
        self.kind = kind
        self.apiTriesSinceLastSuccess = apiTriesSinceLastSuccess
        self.rateLimitedUntil = rateLimitedUntil
        self.rateLimitIsServerProvided = rateLimitIsServerProvided
        self.lastKnownSessionResetsAt = lastKnownSessionResetsAt
        self.lastKnownWeeklyResetsAt = lastKnownWeeklyResetsAt
        self.lastKnownSessionPercent = lastKnownSessionPercent
        self.lastKnownWeeklyPercent = lastKnownWeeklyPercent
    }

    var effectiveSessionResetsAt: Date? {
        if case .ok(_, _, _, let d) = kind { return d ?? lastKnownSessionResetsAt }
        return lastKnownSessionResetsAt
    }

    var effectiveWeeklyResetsAt: Date? {
        if case .ok(_, _, let d, _) = kind { return d ?? lastKnownWeeklyResetsAt }
        return lastKnownWeeklyResetsAt
    }

    var statusName: String {
        switch kind {
        case .loading: return "loading"
        case .ok: return "okay"
        case .unauthenticated: return "unauth"
        case .error: return "error"
        }
    }

    var statusDisplayName: String {
        switch kind {
        case .loading: return Strings.Status.loading
        case .ok: return Strings.Status.ok
        case .unauthenticated: return Strings.Status.unauth
        case .error: return Strings.Status.error
        }
    }

    var tooltip: String {
        switch kind {
        case .loading: return Strings.Tooltip.loading
        case .ok(let s, let w, let wr, let sr):
            var t = "Session: \(s)%  •  Weekly: \(w)%"
            if let sr { t += "\nSession resets: \(DateUtils.formatReset(sr))" }
            if let wr { t += "\nWeekly resets: \(DateUtils.formatReset(wr))" }
            return t
        case .unauthenticated: return Strings.Tooltip.unauthenticated
        case .error(let m): return "Error: \(m)"
        }
    }

    var debugDescription: String {
        switch kind {
        case .loading: return "loading"
        case .ok(let s, let w, _, _): return "ok(session=\(s)%, weekly=\(w)%)"
        case .unauthenticated: return "unauthenticated (tries=\(apiTriesSinceLastSuccess))"
        case .error(let m): return "error(\(m)) (tries=\(apiTriesSinceLastSuccess))"
        }
    }
}
