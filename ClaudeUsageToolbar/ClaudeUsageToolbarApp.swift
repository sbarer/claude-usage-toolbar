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
    private let statusItemHorizontalPadding: CGFloat = 12
    private let statusItemImageWidth: CGFloat = 18
    private let statusItemImageTitleSpacing: CGFloat = 4
    private let minimumStatusItemTitleWidth = NSAttributedString(
        string: "...",
        attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
    ).size().width
    private var statusItem: NSStatusItem!
    private var monitor: UsageMonitor!
    private var lifecycle: ClaudeAppLifecycle!
    private var activityWatcher: ActivityWatcher!
    private var wakeObserver: NSObjectProtocol?
    private var lastState: UsageState?
    private lazy var claudeLogoImage: NSImage? = {
        guard let image = NSImage(named: "claude-logo")?.copy() as? NSImage else {
            return nil
        }
        image.size = NSSize(width: statusItemImageWidth, height: statusItemImageWidth)
        image.isTemplate = false
        return image
    }()

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
        requestKeychainAccessThenStartMonitoring()

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

        let statusMenuItem = NSMenuItem(
            title: "Status: \((lastState ?? UsageState(kind: .loading)).statusDisplayName)",
            action: #selector(openUsageDebugLog),
            keyEquivalent: ""
        )
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

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

    @objc private func openUsageDebugLog() {
        NSWorkspace.shared.open(UsageAPIDebugLog.ensureFileExists())
    }

    private func requestKeychainAccessThenStartMonitoring() {
        KeychainTokenStore.requestAccess { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.monitor.start()
            case .failure(KeychainTokenStore.Error.notFound):
                self.render(UsageState(kind: .unauthenticated))
            case .failure(let error):
                self.render(UsageState(kind: .error("keychain: \(error)")))
            }
        }
    }

    private func renderPlaceholder() {
        render(UsageState(kind: .loading))
    }

    private func render(_ state: UsageState) {
        guard let button = statusItem.button else { return }
        lastState = state
        button.toolTip = state.tooltip
        button.alignment = .center
        button.layer?.cornerRadius = 10

        button.wantsLayer = true
        if MenuBarLabel.isHot(state) {
            button.layer?.backgroundColor = MenuBarLabel.hotBackground.cgColor
        } else {
            button.layer?.backgroundColor = nil
        }

        if MenuBarLabel.usesClaudeLogo(for: state) {
            let title = MenuBarLabel.logoCountTitle(for: state)
            button.image = claudeLogoImage
            button.imagePosition = title.length > 0 ? .imageLeft : .imageOnly
            button.attributedTitle = title
            let titleWidth = title.length > 0 ? statusItemImageTitleSpacing + title.size().width : 0
            updateStatusItemLength(forWidth: statusItemImageWidth + titleWidth)
        } else {
            let title = MenuBarLabel.attributedTitle(for: state)
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = title
            updateStatusItemLength(for: title)
        }
    }

    private func updateStatusItemLength(for title: NSAttributedString) {
        let titleWidth = max(title.size().width, minimumStatusItemTitleWidth)
        updateStatusItemLength(forWidth: titleWidth)
    }

    private func updateStatusItemLength(forWidth contentWidth: CGFloat) {
        let width = max(contentWidth, minimumStatusItemTitleWidth)
        statusItem.length = ceil(width + statusItemHorizontalPadding)
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
