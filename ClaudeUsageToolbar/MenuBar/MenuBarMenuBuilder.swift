import AppKit

private var liveMenuDelegateKey: UInt8 = 0

enum MenuBarMenuBuilder {
    static func build(
        stateProvider: @escaping () -> UsageState?,
        lastFetchAtProvider: @escaping () -> Date?,
        onQuit: @escaping () -> Void,
        onOpenDebugLog: @escaping () -> Void,
        onForceFetch: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        var updaters: [() -> Void] = []

        let state = stateProvider()
        let isRateLimited = state?.rateLimitedUntil.map { $0.timeIntervalSinceNow > 0 } ?? false

        // Status — live
        let statusItem = ClosureMenuItem(title: "", action: onOpenDebugLog)
        menu.addItem(statusItem)
        updaters.append {
            let s = stateProvider()
            let rl = s?.rateLimitedUntil.map { $0.timeIntervalSinceNow > 0 } ?? false
            let name = rl ? Strings.Status.rateLimitedDisplay : (s ?? UsageState(kind: .loading)).statusDisplayName
            statusItem.title = "Status: \(name)"
        }

        // Retry countdown — live, only created when rate limited at open time
        if isRateLimited {
            let retryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            retryItem.isEnabled = false
            menu.addItem(retryItem)
            updaters.append {
                let s = stateProvider()
                guard let until = s?.rateLimitedUntil, until.timeIntervalSinceNow > 0 else {
                    retryItem.isHidden = true
                    return
                }
                retryItem.isHidden = false
                let remaining = max(0, Int(until.timeIntervalSinceNow))
                let m = remaining / 60, sec = remaining % 60
                let countdown = m > 0 ? "\(m)m\(sec)s" : "\(sec)s"
                let suffix = (s?.rateLimitIsServerProvided == true) ? " (RL)" : ""
                retryItem.title = "Retry in \(countdown)\(suffix)"
            }
        }

        // Last fetched — live
        let lastFetchItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastFetchItem.isEnabled = false
        menu.addItem(lastFetchItem)
        updaters.append {
            if let fetchedAt = lastFetchAtProvider() {
                lastFetchItem.title = "Last fetch: \(DateUtils.formatAgo(Date().timeIntervalSince(fetchedAt)))"
            } else {
                lastFetchItem.title = Strings.Menu.lastFetchNever
            }
        }

        menu.addItem(.separator())

        // Show session/weekly data whenever any cached or live values exist
        let hasSessionData: Bool = {
            if case .ok = state?.kind { return true }
            return state?.lastKnownSessionPercent != nil
        }()
        let hasWeeklyData: Bool = {
            if case .ok = state?.kind { return true }
            return state?.lastKnownWeeklyPercent != nil
        }()

        if hasSessionData || hasWeeklyData {
            if hasSessionData {
                let sessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                sessionItem.isEnabled = false
                menu.addItem(sessionItem)
                updaters.append {
                    let s = stateProvider()
                    if case .ok(let pct, _, _, _) = s?.kind {
                        sessionItem.title = "Session: \(pct)%"
                    } else if let pct = s?.lastKnownSessionPercent {
                        sessionItem.title = "Session: \(pct)% (cached)"
                    }
                }

                if let resetsAt = state?.effectiveSessionResetsAt, resetsAt.timeIntervalSinceNow > 0 {
                    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                    updaters.append {
                        let date = stateProvider()?.effectiveSessionResetsAt ?? resetsAt
                        let r = date.timeIntervalSinceNow
                        item.isHidden = r <= 0
                        if r > 0 { item.title = "  Reset: \(DateUtils.formatMenuCountdown(r))" }
                    }
                }
            }

            menu.addItem(.separator())

            if hasWeeklyData {
                let weeklyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                weeklyItem.isEnabled = false
                menu.addItem(weeklyItem)
                updaters.append {
                    let s = stateProvider()
                    if case .ok(_, let pct, _, _) = s?.kind {
                        weeklyItem.title = "Weekly: \(pct)%"
                    } else if let pct = s?.lastKnownWeeklyPercent {
                        weeklyItem.title = "Weekly: \(pct)% (cached)"
                    }
                }

                if let resetsAt = state?.effectiveWeeklyResetsAt, resetsAt.timeIntervalSinceNow > 0 {
                    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                    updaters.append {
                        let date = stateProvider()?.effectiveWeeklyResetsAt ?? resetsAt
                        let r = date.timeIntervalSinceNow
                        item.isHidden = r <= 0
                        if r > 0 { item.title = "  Reset: \(DateUtils.formatMenuCountdown(r, showSeconds: false))" }
                    }
                }
            }

            menu.addItem(.separator())
        }

        menu.addItem(ClosureMenuItem(title: Strings.Menu.forceFetch, action: onForceFetch))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Strings.Menu.restart, action: onQuit))

        let delegate = LiveMenuDelegate(updaters: updaters)
        menu.delegate = delegate
        objc_setAssociatedObject(menu, &liveMenuDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        return menu
    }
}

private final class LiveMenuDelegate: NSObject, NSMenuDelegate {
    private var timer: Timer?
    private let updaters: [() -> Void]

    init(updaters: [() -> Void]) {
        self.updaters = updaters
        super.init()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateAll()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateAll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        timer?.invalidate()
        timer = nil
    }

    private func updateAll() {
        updaters.forEach { $0() }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func invoke() { closure() }
}
