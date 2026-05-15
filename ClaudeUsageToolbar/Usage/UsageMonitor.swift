import Foundation

final class UsageMonitor {
    private let api = UsageAPI()
    private let activityWatcher: ActivityWatcher
    private let onUpdate: (UsageState) -> Void
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "claude-usage-toolbar.monitor")
    private var lastWeeklyPercent: Int = 0
    private var apiTriesSinceLastSuccess: Int = 0
    private(set) var lastFetchAt: Date?
    private static let rateLimitedUntilKey = "rateLimitedUntil"
    private static let cachedSessionPercentKey = "cachedSessionPercent"
    private static let cachedWeeklyPercentKey = "cachedWeeklyPercent"
    private static let cachedSessionResetsAtKey = "cachedSessionResetsAt"
    private static let cachedWeeklyResetsAtKey = "cachedWeeklyResetsAt"
    private static let cachedFetchedAtKey = "cachedFetchedAt"
    private static let cacheMaxAge: TimeInterval = 3600
    private var rateLimitedUntil: Date? {
        get { UserDefaults.standard.object(forKey: Self.rateLimitedUntilKey) as? Date }
        set {
            if let date = newValue { UserDefaults.standard.set(date, forKey: Self.rateLimitedUntilKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.rateLimitedUntilKey) }
        }
    }
    private var sessionFullUntil: Date?
    private var lastKnownSessionResetsAt: Date?
    private var lastKnownWeeklyResetsAt: Date?
    private var lastKnownSessionPercent: Int?
    private var lastKnownWeeklyPercent: Int?
    private var rateLimitIsServerProvided: Bool = false
    private let weeklyAlertThreshold = 90

    init(activityWatcher: ActivityWatcher, onUpdate: @escaping (UsageState) -> Void) {
        self.activityWatcher = activityWatcher
        self.onUpdate = onUpdate
    }

    func start() {
        NSLog("[ClaudeUsageToolbar] UsageMonitor: starting")
        // Prime last-known values from any previously persisted cache (no age limit).
        let ud = UserDefaults.standard
        if ud.object(forKey: Self.cachedFetchedAtKey) != nil {
            lastKnownSessionPercent = ud.integer(forKey: Self.cachedSessionPercentKey)
            lastKnownWeeklyPercent = ud.integer(forKey: Self.cachedWeeklyPercentKey)
            lastKnownSessionResetsAt = ud.object(forKey: Self.cachedSessionResetsAtKey) as? Date
            lastKnownWeeklyResetsAt = ud.object(forKey: Self.cachedWeeklyResetsAtKey) as? Date
            NSLog("[ClaudeUsageToolbar] UsageMonitor: primed last-known session=%d%% weekly=%d%%", lastKnownSessionPercent ?? -1, lastKnownWeeklyPercent ?? -1)
        }
        if let cached = loadCachedState() {
            NSLog("[ClaudeUsageToolbar] UsageMonitor: loaded cached state: %@", cached.debugDescription)
            if case .ok(_, let w, _, _) = cached.kind { lastWeeklyPercent = w }
            DispatchQueue.main.async { [weak self] in self?.onUpdate(cached) }
        } else {
            NSLog("[ClaudeUsageToolbar] UsageMonitor: no valid cached state")
            // Cache is expired but we still have last-known values — emit a loading state so
            // the menu can show them while the fresh fetch is in flight.
            if lastKnownSessionPercent != nil || lastKnownWeeklyPercent != nil {
                let primed = UsageState(
                    kind: .loading,
                    lastKnownSessionResetsAt: lastKnownSessionResetsAt,
                    lastKnownWeeklyResetsAt: lastKnownWeeklyResetsAt,
                    lastKnownSessionPercent: lastKnownSessionPercent,
                    lastKnownWeeklyPercent: lastKnownWeeklyPercent
                )
                DispatchQueue.main.async { [weak self] in self?.onUpdate(primed) }
            }
        }
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
    
    func forceFetch() {
        NSLog("[ClaudeUsageToolbar] Force fetch requested")
        // Clear rate limit and session full restrictions
        rateLimitedUntil = nil
        sessionFullUntil = nil
        // Reset timer to normal interval
        rescheduleTimer()
        // Trigger immediate fetch
        fetchNow(reason: "force-fetch")
    }

    private func performFetch(reason: String) {
        if let until = rateLimitedUntil, Date() < until {
            let remaining = Int(until.timeIntervalSinceNow)
            NSLog("[ClaudeUsageToolbar] skipping fetch, rate limited for %ds", remaining)
            return
        }
        if let until = sessionFullUntil, Date() < until {
            let remaining = Int(until.timeIntervalSinceNow)
            NSLog("[ClaudeUsageToolbar] skipping fetch, session full for %ds", remaining)
            return
        }
        NSLog("[ClaudeUsageToolbar] poll reason=%@", reason)
        DispatchQueue.main.async { [weak self] in self?.lastFetchAt = Date() }
        api.fetch(reason: reason) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let resp, _):
                    self.apiTriesSinceLastSuccess = 0
                    self.rateLimitedUntil = nil
                    self.rateLimitIsServerProvided = false
                    let session = Int((resp.fiveHour?.utilization ?? 0))
                    if session >= 100, let resetsAt = resp.fiveHour?.resetsAt, resetsAt.timeIntervalSinceNow > 0 {
                        self.sessionFullUntil = resetsAt
                    } else {
                        self.sessionFullUntil = nil
                    }
                    self.lastKnownSessionResetsAt = resp.fiveHour?.resetsAt
                    self.lastKnownWeeklyResetsAt = resp.sevenDay?.resetsAt
                    let weekly = Int((resp.sevenDay?.utilization ?? 0))
                    self.lastKnownSessionPercent = session
                    self.lastKnownWeeklyPercent = weekly
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
                    self.saveCachedState(session: session, weekly: weekly,
                                        sessionResetsAt: resp.fiveHour?.resetsAt,
                                        weeklyResetsAt: resp.sevenDay?.resetsAt)
                    self.onUpdate(state)
                    self.maybeFireWeeklyAlert(weekly: weekly, resetsAt: resp.sevenDay?.resetsAt)
                    self.lastWeeklyPercent = weekly
                case .unauthenticated(let attempts):
                    self.apiTriesSinceLastSuccess += attempts
                    NSLog("[ClaudeUsageToolbar] fetched: unauthenticated")
                    self.onUpdate(UsageState(kind: .unauthenticated, apiTriesSinceLastSuccess: self.apiTriesSinceLastSuccess, lastKnownSessionResetsAt: self.lastKnownSessionResetsAt, lastKnownWeeklyResetsAt: self.lastKnownWeeklyResetsAt, lastKnownSessionPercent: self.lastKnownSessionPercent, lastKnownWeeklyPercent: self.lastKnownWeeklyPercent))
                case .rateLimited(let retryAfter, let attempts):
                    self.apiTriesSinceLastSuccess += attempts
                    let isServerProvided = retryAfter.map { $0 > 0 } ?? false
                    let seconds = retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? UsageFetchResult.rateLimitFallbackSeconds
                    self.rateLimitedUntil = Date().addingTimeInterval(seconds)
                    self.rateLimitIsServerProvided = isServerProvided
                    NSLog("[ClaudeUsageToolbar] fetched: rate-limited, retry-after=%ds%@", Int(seconds), isServerProvided ? "" : " (defaulted)")
                    self.onUpdate(UsageState(kind: .error("Rate limited"), apiTriesSinceLastSuccess: self.apiTriesSinceLastSuccess, rateLimitedUntil: self.rateLimitedUntil, rateLimitIsServerProvided: isServerProvided, lastKnownSessionResetsAt: self.lastKnownSessionResetsAt, lastKnownWeeklyResetsAt: self.lastKnownWeeklyResetsAt, lastKnownSessionPercent: self.lastKnownSessionPercent, lastKnownWeeklyPercent: self.lastKnownWeeklyPercent))
                case .failure(let err, let attempts):
                    self.apiTriesSinceLastSuccess += attempts
                    NSLog("[ClaudeUsageToolbar] fetch error: %@", err)
                    self.onUpdate(UsageState(kind: .error(err), apiTriesSinceLastSuccess: self.apiTriesSinceLastSuccess, lastKnownSessionResetsAt: self.lastKnownSessionResetsAt, lastKnownWeeklyResetsAt: self.lastKnownWeeklyResetsAt, lastKnownSessionPercent: self.lastKnownSessionPercent, lastKnownWeeklyPercent: self.lastKnownWeeklyPercent))
                }
            }
        }
    }

    private func loadCachedState() -> UsageState? {
        let ud = UserDefaults.standard
        guard let fetchedAt = ud.object(forKey: Self.cachedFetchedAtKey) as? Date,
              Date().timeIntervalSince(fetchedAt) < Self.cacheMaxAge else { return nil }
        let session = ud.integer(forKey: Self.cachedSessionPercentKey)
        let weekly = ud.integer(forKey: Self.cachedWeeklyPercentKey)
        let sessionResetsAt = ud.object(forKey: Self.cachedSessionResetsAtKey) as? Date
        let weeklyResetsAt = ud.object(forKey: Self.cachedWeeklyResetsAtKey) as? Date
        return UsageState(
            kind: .ok(sessionPercent: session, weeklyPercent: weekly, weeklyResetsAt: weeklyResetsAt, sessionResetsAt: sessionResetsAt),
            lastKnownSessionResetsAt: sessionResetsAt,
            lastKnownWeeklyResetsAt: weeklyResetsAt
        )
    }

    private func saveCachedState(session: Int, weekly: Int, sessionResetsAt: Date?, weeklyResetsAt: Date?) {
        let ud = UserDefaults.standard
        ud.set(session, forKey: Self.cachedSessionPercentKey)
        ud.set(weekly, forKey: Self.cachedWeeklyPercentKey)
        if let d = sessionResetsAt { ud.set(d, forKey: Self.cachedSessionResetsAtKey) }
        else { ud.removeObject(forKey: Self.cachedSessionResetsAtKey) }
        if let d = weeklyResetsAt { ud.set(d, forKey: Self.cachedWeeklyResetsAtKey) }
        else { ud.removeObject(forKey: Self.cachedWeeklyResetsAtKey) }
        ud.set(Date(), forKey: Self.cachedFetchedAtKey)
    }

    private func maybeFireWeeklyAlert(weekly: Int, resetsAt: Date?) {
        guard weekly >= weeklyAlertThreshold, lastWeeklyPercent < weeklyAlertThreshold else {
            if weekly >= weeklyAlertThreshold {
                NSLog("[ClaudeUsageToolbar] UsageMonitor: weekly alert suppressed (already at/above threshold, lastWeekly=%d)", lastWeeklyPercent)
            }
            return
        }
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
        let interval: TimeInterval = since < 3600 ? 60 : 330
        NSLog("[ClaudeUsageToolbar] UsageMonitor: poll interval=%ds (last activity %.0fs ago)", Int(interval), since)
        return interval
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
