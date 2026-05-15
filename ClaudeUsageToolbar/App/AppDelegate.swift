import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private var monitor: UsageMonitor!
    private var lifecycle: ClaudeAppLifecycle!
    private var activityWatcher: ActivityWatcher!
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConsoleLog.initialize()
        _ = UsageAPIDebugLog.ensureFileExists()
        NSLog("[ClaudeUsageToolbar] === App launched ===")

        LaunchAgentInstaller.installIfNeeded()

        lifecycle = ClaudeAppLifecycle(
            onClaudeQuit: { [weak self] in self?.handleClaudeQuit() }
        )

        guard lifecycle.isClaudeRunning else {
            NSLog("[ClaudeUsageToolbar] Claude.app not running at launch — terminating")
            NSApp.terminate(nil)
            return
        }
        NSLog("[ClaudeUsageToolbar] Claude.app is running, continuing startup")

        menuBarController = MenuBarController(
            onLeftClick: { ClaudeUsageOpener.open() },
            onOptionClick: { [weak self] in self?.showMenu() }
        )

        activityWatcher = ActivityWatcher()
        monitor = UsageMonitor(activityWatcher: activityWatcher) { [weak self] state in
            self?.menuBarController.render(state)
        }
        menuBarController.render(UsageState(kind: .loading))
        requestKeychainAccessThenStartMonitoring()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            NSLog("[ClaudeUsageToolbar] Wake from sleep — triggering fetch")
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

    private func showMenu() {
        let menu = MenuBarMenuBuilder.build(
            stateProvider: { [weak self] in self?.menuBarController.currentState },
            lastFetchAtProvider: { [weak self] in self?.monitor.lastFetchAt },
            onRestart: { [weak self] in self?.restartApp() },
            onQuit: { NSApp.terminate(nil) },
            onOpenDebugLog: { NSWorkspace.shared.open(UsageAPIDebugLog.ensureFileExists()) },
            onOpenConsoleLog: { NSWorkspace.shared.open(AppConsoleLog.ensureFileExists()) },
            onForceFetch: { [weak self] in self?.monitor.forceFetch() }
        )
        menuBarController.showMenu(menu)
    }

    private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func requestKeychainAccessThenStartMonitoring() {
        KeychainTokenStore.requestAccess { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                NSLog("[ClaudeUsageToolbar] Keychain access granted — starting monitor")
                self.monitor.start()
            case .failure(KeychainTokenStore.Error.notFound):
                NSLog("[ClaudeUsageToolbar] Keychain: token not found — showing unauthenticated")
                self.menuBarController.render(UsageState(kind: .unauthenticated))
            case .failure(let error):
                NSLog("[ClaudeUsageToolbar] Keychain: access error — %@", "\(error)")
                self.menuBarController.render(UsageState(kind: .error("keychain: \(error)")))
            }
        }
    }
}
