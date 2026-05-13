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

    init(kind: Kind, apiTriesSinceLastSuccess: Int = 0) {
        self.kind = kind
        self.apiTriesSinceLastSuccess = apiTriesSinceLastSuccess
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
        case .loading: return "Loading"
        case .ok: return "Okay"
        case .unauthenticated: return "Unauth"
        case .error: return "Error"
        }
    }

    var tooltip: String {
        switch kind {
        case .loading: return "Loading Claude usage…"
        case .ok(let s, let w, let wr, let sr):
            var t = "Session: \(s)%  •  Weekly: \(w)%"
            if let sr { t += "\nSession resets: \(Self.formatReset(sr))" }
            if let wr { t += "\nWeekly resets: \(Self.formatReset(wr))" }
            return t
        case .unauthenticated: return "Not authenticated — run `claude` to sign in"
        case .error(let m): return "Error: \(m)"
        }
    }

    static func formatReset(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma, MMM d"
        return f.string(from: date)
    }
}
