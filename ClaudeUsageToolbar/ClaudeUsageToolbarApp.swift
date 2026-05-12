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
        openClaudeUsage()
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
        button.attributedTitle = MenuBarLabel.attributedTitle(for: state)
        button.toolTip = state.tooltip
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
