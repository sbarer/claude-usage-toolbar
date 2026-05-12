import SwiftUI
import AppKit

@main
struct ClaudeUsageToolbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: UsageMonitor!
    private var lifecycle: ClaudeAppLifecycle!
    private var activityWatcher: ActivityWatcher!
    private var wakeObserver: NSObjectProtocol?
    private var lastState: UsageState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchAgentInstaller.installIfNeeded()

        lifecycle = ClaudeAppLifecycle(
            onClaudeQuit: { [weak self] in self?.handleClaudeQuit() }
        )

        guard lifecycle.isClaudeRunning else {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        activityWatcher = ActivityWatcher()
        monitor = UsageMonitor(activityWatcher: activityWatcher) { [weak self] state in
            self?.render(state)
        }
        renderPlaceholder()
        monitor.start()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.monitor.fetchNow(reason: "wake-from-sleep")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        lifecycle?.stop()
        activityWatcher?.stop()
    }

    private func handleClaudeQuit() {
        NSApp.terminate(nil)
    }

    @objc private func handleClick(_ sender: Any?) {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        if optionHeld {
            showMenu()
        } else {
            openClaudeUsage()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        if case .ok(let session, let weekly, let weeklyResetsAt, let sessionResetsAt) = lastState?.kind {
            let sessionItem = NSMenuItem(title: "Session: \(session)%", action: nil, keyEquivalent: "")
            sessionItem.isEnabled = false
            menu.addItem(sessionItem)

            if let resetsAt = sessionResetsAt {
                let remaining = resetsAt.timeIntervalSinceNow
                if remaining > 0 {
                    let item = NSMenuItem(title: "  Resets in \(MenuBarLabel.formatCountdownLong(remaining))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())

            let weeklyItem = NSMenuItem(title: "Weekly: \(weekly)%", action: nil, keyEquivalent: "")
            weeklyItem.isEnabled = false
            menu.addItem(weeklyItem)

            if let resetsAt = weeklyResetsAt {
                let remaining = resetsAt.timeIntervalSinceNow
                if remaining > 0 {
                    let item = NSMenuItem(title: "  Resets in \(MenuBarLabel.formatCountdownLong(remaining))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restartApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: ""))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func renderPlaceholder() {
        guard let button = statusItem.button else { return }
        let attr = NSAttributedString(
            string: "…",
            attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
        )
        button.attributedTitle = attr
    }

    private func render(_ state: UsageState) {
        guard let button = statusItem.button else { return }
        lastState = state
        button.attributedTitle = MenuBarLabel.attributedTitle(for: state)
        button.toolTip = state.tooltip
        button.alignment = .center
        button.layer?.cornerRadius = 10

        button.wantsLayer = true
        if MenuBarLabel.isHot(state) {
            button.layer?.backgroundColor = MenuBarLabel.hotBackground.cgColor
        } else {
            button.layer?.backgroundColor = nil
        }
        button.sizeToFit()
    }
}

private func openClaudeUsage() {
    if let url = URL(string: "claude://usage") {
        NSWorkspace.shared.open(url)
    }
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg, completionHandler: nil)
    }
}
