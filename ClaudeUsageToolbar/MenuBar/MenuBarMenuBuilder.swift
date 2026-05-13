import AppKit

enum MenuBarMenuBuilder {
    static func build(
        state: UsageState?,
        onRestart: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onOpenDebugLog: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(ClosureMenuItem(
            title: "Status: \((state ?? UsageState(kind: .loading)).statusDisplayName)",
            action: onOpenDebugLog
        ))
        menu.addItem(.separator())

        if case .ok(let session, let weekly, let weeklyResetsAt, let sessionResetsAt) = state?.kind {
            let sessionItem = NSMenuItem(title: "Session: \(session)%", action: nil, keyEquivalent: "")
            sessionItem.isEnabled = false
            menu.addItem(sessionItem)

            if let resetsAt = sessionResetsAt, resetsAt.timeIntervalSinceNow > 0 {
                let item = NSMenuItem(
                    title: "  Resets in \(MenuBarLabel.formatCountdownLong(resetsAt.timeIntervalSinceNow))",
                    action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(.separator())

            let weeklyItem = NSMenuItem(title: "Weekly: \(weekly)%", action: nil, keyEquivalent: "")
            weeklyItem.isEnabled = false
            menu.addItem(weeklyItem)

            if let resetsAt = weeklyResetsAt, resetsAt.timeIntervalSinceNow > 0 {
                let item = NSMenuItem(
                    title: "  Resets in \(MenuBarLabel.formatCountdownLong(resetsAt.timeIntervalSinceNow))",
                    action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(.separator())
        }

        menu.addItem(ClosureMenuItem(title: "Restart", action: onRestart))
        menu.addItem(ClosureMenuItem(title: "Quit", action: onQuit))
        return menu
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
