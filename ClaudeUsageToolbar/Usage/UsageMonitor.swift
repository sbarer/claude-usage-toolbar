import Foundation

@MainActor
final class UsageMonitor {
    private let api = UsageAPI()
    private let activityWatcher: ActivityWatcher
    private let onUpdate: (UsageState) -> Void
    private var timer: Timer?
    private var isFetching = false
    private var apiTriesSinceLastSuccess: Int = 0
    private(set) var lastFetchAt: Date?
    private static let cacheMaxAge: TimeInterval = 3600
    private var rateLimitedUntil: Date? {
        get { UserDefaults.standard.object(forKey: Strings.Defaults.rateLimitedUntil) as? Date }
        set {
            if let date = newValue { UserDefaults.standard.set(date, forKey: Strings.Defaults.rateLimitedUntil) }
            else { UserDefaults.standard.removeObject(forKey: Strings.Defaults.rateLimitedUntil) }
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
        NSLog("UsageMonitor: starting")
        let ud = UserDefaults.standard
        if ud.object(forKey: Strings.Defaults.cachedFetchedAt) != nil {
            lastKnownSessionPercent = ud.integer(forKey: Strings.Defaults.cachedSessionPercent)
            lastKnownWeeklyPercent = ud.integer(forKey: Strings.Defaults.cachedWeeklyPercent)
            lastKnownSessionResetsAt = ud.object(forKey: Strings.Defaults.cachedSessionResetsAt) as? Date
            lastKnownWeeklyResetsAt = ud.object(forKey: Strings.Defaults.cachedWeeklyResetsAt) as? Date
            NSLog("UsageMonitor: primed last-known usages session=%d%% weekly=%d%%", lastKnownSessionPercent ?? -1, lastKnownWeeklyPercent ?? -1)
            if let s = lastKnownSessionResetsAt, let w = lastKnownWeeklyResetsAt {
                NSLog("UsageMonitor: primed last-known resets session=\(DateUtils.formatReset(s)) weekly=\(DateUtils.formatReset(w))")
            }
        }
        if let cached = loadCachedState() {
            NSLog("UsageMonitor: loaded cached state: %@", cached.debugDescription)
            onUpdate(cached)
        } else {
            NSLog("UsageMonitor: no valid cached state")
            if lastKnownSessionPercent != nil || lastKnownWeeklyPercent != nil {
                onUpdate(UsageState(
                    kind: .loading,
                    lastKnownSessionResetsAt: lastKnownSessionResetsAt,
                    lastKnownWeeklyResetsAt: lastKnownWeeklyResetsAt,
                    lastKnownSessionPercent: lastKnownSessionPercent,
                    lastKnownWeeklyPercent: lastKnownWeeklyPercent
                ))
            }
        }
        activityWatcher.start { [weak self] in
            self?.fetchNow(reason: "activity")
            // This call to rescheduleTimer() is also in a nonisolated context.
            // It should also be dispatched to the MainActor to prevent a similar warning.
            Task { @MainActor in
                self?.rescheduleTimer()
            }
        }
        fetchNow(reason: "startup")
        rescheduleTimer()
    }

    func fetchNow(reason: String) {
        Task { await performFetch(reason: reason) }
    }

    func forceFetch() {
        NSLog("Force fetch requested")
        rateLimitedUntil = nil
        sessionFullUntil = nil
        rescheduleTimer()
        fetchNow(reason: "force-fetch")
    }

    private func performFetch(reason: String) async {
        guard !isFetching else {
            NSLog("skipping fetch, already in flight")
            return
        }
        if let until = rateLimitedUntil, Date() < until {
            NSLog("skipping fetch, rate limited for %ds", Int(until.timeIntervalSinceNow))
            return
        }
        if let until = sessionFullUntil, Date() < until {
            NSLog("skipping fetch, session full for %ds", Int(until.timeIntervalSinceNow))
            return
        }
        NSLog("poll reason=%@", reason)
        isFetching = true
        lastFetchAt = Date()
        let result = await api.fetch(reason: reason)
        isFetching = false
        handleFetchResult(result)
    }

    private func handleFetchResult(_ result: UsageFetchResult) {
        switch result {
        case .success(let resp, _):
            apiTriesSinceLastSuccess = 0
            rateLimitedUntil = nil
            rateLimitIsServerProvided = false
            let session = Int(resp.fiveHour?.utilization ?? 0)
            if session >= 100, let resetsAt = resp.fiveHour?.resetsAt, resetsAt.timeIntervalSinceNow > 0 {
                sessionFullUntil = resetsAt
            } else {
                sessionFullUntil = nil
            }
            lastKnownSessionResetsAt = resp.fiveHour?.resetsAt
            lastKnownWeeklyResetsAt = resp.sevenDay?.resetsAt
            let weekly = Int(resp.sevenDay?.utilization ?? 0)
            NSLog("fetched session=%d%% weekly=%d%% sessionResets=%@ weeklyResets=%@",
                  session, weekly,
                  resp.fiveHour?.resetsAt.map { "\($0)" } ?? "nil",
                  resp.sevenDay?.resetsAt.map { "\($0)" } ?? "nil")
            let state = UsageState(kind: .ok(.init(
                sessionPercent: session,
                weeklyPercent: weekly,
                weeklyResetsAt: resp.sevenDay?.resetsAt,
                sessionResetsAt: resp.fiveHour?.resetsAt
            )))
            saveCachedState(session: session, weekly: weekly,
                            sessionResetsAt: resp.fiveHour?.resetsAt,
                            weeklyResetsAt: resp.sevenDay?.resetsAt)
            onUpdate(state)
            // Read lastKnownWeeklyPercent (previous value) for edge detection before updating it
            maybeFireWeeklyAlert(newWeekly: weekly, resetsAt: resp.sevenDay?.resetsAt)
            lastKnownSessionPercent = session
            lastKnownWeeklyPercent = weekly

        case .unauthenticated(let attempts):
            apiTriesSinceLastSuccess += attempts
            NSLog("fetched: unauthenticated")
            onUpdate(UsageState(kind: .unauthenticated,
                                apiTriesSinceLastSuccess: apiTriesSinceLastSuccess,
                                lastKnownSessionResetsAt: lastKnownSessionResetsAt,
                                lastKnownWeeklyResetsAt: lastKnownWeeklyResetsAt,
                                lastKnownSessionPercent: lastKnownSessionPercent,
                                lastKnownWeeklyPercent: lastKnownWeeklyPercent))

        case .rateLimited(let retryAfter, let attempts):
            apiTriesSinceLastSuccess += attempts
            let isServerProvided = retryAfter.map { $0 > 0 } ?? false
            let seconds = retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? UsageFetchResult.rateLimitFallbackSeconds
            rateLimitedUntil = Date().addingTimeInterval(seconds)
            rateLimitIsServerProvided = isServerProvided
            NSLog("fetched: rate-limited, retry-after=%ds%@", Int(seconds), isServerProvided ? "" : " (defaulted)")
            onUpdate(UsageState(kind: .error(Strings.Status.rateLimited),
                                apiTriesSinceLastSuccess: apiTriesSinceLastSuccess,
                                rateLimitedUntil: rateLimitedUntil,
                                rateLimitIsServerProvided: isServerProvided,
                                lastKnownSessionResetsAt: lastKnownSessionResetsAt,
                                lastKnownWeeklyResetsAt: lastKnownWeeklyResetsAt,
                                lastKnownSessionPercent: lastKnownSessionPercent,
                                lastKnownWeeklyPercent: lastKnownWeeklyPercent))

        case .failure(let err, let attempts):
            apiTriesSinceLastSuccess += attempts
            NSLog("fetch error: %@", err)
            onUpdate(UsageState(kind: .error(err),
                                apiTriesSinceLastSuccess: apiTriesSinceLastSuccess,
                                lastKnownSessionResetsAt: lastKnownSessionResetsAt,
                                lastKnownWeeklyResetsAt: lastKnownWeeklyResetsAt,
                                lastKnownSessionPercent: lastKnownSessionPercent,
                                lastKnownWeeklyPercent: lastKnownWeeklyPercent))
        }
    }

    // MARK: - Cache

    private func loadCachedState() -> UsageState? {
        let ud = UserDefaults.standard
        guard let fetchedAt = ud.object(forKey: Strings.Defaults.cachedFetchedAt) as? Date,
              Date().timeIntervalSince(fetchedAt) < Self.cacheMaxAge else { return nil }
        let session = ud.integer(forKey: Strings.Defaults.cachedSessionPercent)
        let weekly = ud.integer(forKey: Strings.Defaults.cachedWeeklyPercent)
        let sessionResetsAt = ud.object(forKey: Strings.Defaults.cachedSessionResetsAt) as? Date
        let weeklyResetsAt = ud.object(forKey: Strings.Defaults.cachedWeeklyResetsAt) as? Date
        return UsageState(
            kind: .ok(.init(sessionPercent: session, weeklyPercent: weekly,
                            weeklyResetsAt: weeklyResetsAt, sessionResetsAt: sessionResetsAt)),
            lastKnownSessionResetsAt: sessionResetsAt,
            lastKnownWeeklyResetsAt: weeklyResetsAt
        )
    }

    private func saveCachedState(session: Int, weekly: Int, sessionResetsAt: Date?, weeklyResetsAt: Date?) {
        let ud = UserDefaults.standard
        ud.set(session, forKey: Strings.Defaults.cachedSessionPercent)
        ud.set(weekly, forKey: Strings.Defaults.cachedWeeklyPercent)
        if let d = sessionResetsAt { ud.set(d, forKey: Strings.Defaults.cachedSessionResetsAt) }
        else { ud.removeObject(forKey: Strings.Defaults.cachedSessionResetsAt) }
        if let d = weeklyResetsAt { ud.set(d, forKey: Strings.Defaults.cachedWeeklyResetsAt) }
        else { ud.removeObject(forKey: Strings.Defaults.cachedWeeklyResetsAt) }
        ud.set(Date(), forKey: Strings.Defaults.cachedFetchedAt)
    }

    // MARK: - Weekly alert

    private func maybeFireWeeklyAlert(newWeekly: Int, resetsAt: Date?) {
        let prev = lastKnownWeeklyPercent ?? 0
        guard newWeekly >= weeklyAlertThreshold, prev < weeklyAlertThreshold else {
            if newWeekly >= weeklyAlertThreshold {
                NSLog("UsageMonitor: weekly alert suppressed (already at/above threshold, lastWeekly=%d)", prev)
            }
            return
        }
        guard let resetsAt else { return }
        let resetIso = DateUtils.iso.string(from: resetsAt)
        let already = UserDefaults.standard.string(forKey: Strings.Defaults.lastAlertedWeeklyResetWindow)
        if already == resetIso { return }
        WeeklyAlert.show(percent: newWeekly, resetsAt: resetsAt)
        UserDefaults.standard.set(resetIso, forKey: Strings.Defaults.lastAlertedWeeklyResetWindow)
    }

    // MARK: - Timer

    private func currentInterval() -> TimeInterval {
        let since = Date().timeIntervalSince(activityWatcher.lastActivityAt)
        let interval: TimeInterval
        if since < 60 { interval = 15 }
        else if since < 3600 { interval = 60 }
        else { interval = 300 }
        NSLog("UsageMonitor: poll interval=%ds (last activity %.0fs ago)", Int(interval), since)
        return interval
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        let interval = currentInterval()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { await self.performFetch(reason: "timer-\(Int(interval))s") }
            // Fix: Dispatch the call to rescheduleTimer() to the MainActor
            Task { @MainActor in
                self.rescheduleTimer()
            }
        }
    }
}
