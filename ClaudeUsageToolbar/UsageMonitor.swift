import Foundation
import AppKit

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
            if let sr { t += "\nWeekly resets: \(Self.formatReset(sr))" }
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

final class UsageMonitor {
    private let api = UsageAPI()
    private let activityWatcher: ActivityWatcher
    private let onUpdate: (UsageState) -> Void
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "claude-usage-toolbar.monitor")
    private var lastWeeklyPercent: Int = 0
    private var apiTriesSinceLastSuccess: Int = 0
    private let weeklyAlertThreshold = 90

    init(activityWatcher: ActivityWatcher, onUpdate: @escaping (UsageState) -> Void) {
        self.activityWatcher = activityWatcher
        self.onUpdate = onUpdate
    }

    func start() {
        activityWatcher.start { [weak self] in
            self?.fetchNow(reason: "activity")
            self?.rescheduleTimer()
        }
        fetchNow(reason: "startup")
        rescheduleTimer()
    }

    func fetchNow(reason: String) {
        queue.async { [weak self] in
            self?.performFetch(reason: reason)
        }
    }

    private func performFetch(reason: String) {
        NSLog("[ClaudeUsageToolbar] poll reason=%@", reason)
        api.fetch(reason: reason) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let resp, _):
                    self.apiTriesSinceLastSuccess = 0
                    let session = Int((resp.fiveHour?.utilization ?? 0))
                    let weekly = Int((resp.sevenDay?.utilization ?? 0))
                    NSLog("[ClaudeUsageToolbar] fetched session=%d%% weekly=%d%% sessionResets=%@ weeklyResets=%@",
                          session, weekly,
                          resp.fiveHour?.resetsAt.map { "\($0)" } ?? "nil",
                          resp.sevenDay?.resetsAt.map { "\($0)" } ?? "nil")
                    let state = UsageState(kind: .ok(
                        sessionPercent: session,
                        weeklyPercent: weekly,
                        weeklyResetsAt: resp.sevenDay?.resetsAt,
                        sessionResetsAt: resp.fiveHour?.resetsAt
                    ))
                    self.onUpdate(state)
                    self.maybeFireWeeklyAlert(weekly: weekly, resetsAt: resp.sevenDay?.resetsAt)
                    self.lastWeeklyPercent = weekly
                case .unauthenticated(let attempts):
                    self.apiTriesSinceLastSuccess += attempts
                    NSLog("[ClaudeUsageToolbar] fetched: unauthenticated")
                    self.onUpdate(UsageState(kind: .unauthenticated, apiTriesSinceLastSuccess: self.apiTriesSinceLastSuccess))
                case .rateLimited(let attempts):
                    self.apiTriesSinceLastSuccess += attempts
                    NSLog("[ClaudeUsageToolbar] fetched: rate-limited")
                    NSLog("[ClaudeUsageToolbar] rate-limited result: %@", String(describing: result))
                    self.onUpdate(UsageState(kind: .error("Rate limited"), apiTriesSinceLastSuccess: self.apiTriesSinceLastSuccess))
                case .failure(let err, let attempts):
                    self.apiTriesSinceLastSuccess += attempts
                    NSLog("[ClaudeUsageToolbar] fetch error: %@", err)
                    self.onUpdate(UsageState(kind: .error(err), apiTriesSinceLastSuccess: self.apiTriesSinceLastSuccess))
                }
            }
        }
    }

    private func maybeFireWeeklyAlert(weekly: Int, resetsAt: Date?) {
        guard weekly >= weeklyAlertThreshold, lastWeeklyPercent < weeklyAlertThreshold else { return }
        guard let resetsAt else { return }
        let key = "lastAlertedWeeklyResetWindow"
        let resetIso = ISO8601DateFormatter().string(from: resetsAt)
        let already = UserDefaults.standard.string(forKey: key)
        if already == resetIso { return }
        WeeklyAlert.show(percent: weekly, resetsAt: resetsAt)
        UserDefaults.standard.set(resetIso, forKey: key)
    }

    private func currentInterval() -> TimeInterval {
        let since = Date().timeIntervalSince(activityWatcher.lastActivityAt)
        if since < 120 { return 15 }
        if since < 3600 { return 60 }
        return 300
    }

    private func rescheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = currentInterval()
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.performFetch(reason: "timer-\(Int(interval))s")
            let next = self.currentInterval()
            if abs(next - interval) > 0.1 {
                DispatchQueue.main.async { self.rescheduleTimer() }
            }
        }
        timer = t
        t.resume()
    }
}
