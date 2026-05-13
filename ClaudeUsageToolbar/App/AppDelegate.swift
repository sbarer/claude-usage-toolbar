import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
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
            state: menuBarController.currentState,
            onRestart: { [weak self] in self?.restartApp() },
            onQuit: { NSApp.terminate(nil) },
            onOpenDebugLog: { NSWorkspace.shared.open(UsageAPIDebugLog.ensureFileExists()) }
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
                self.monitor.start()
            case .failure(KeychainTokenStore.Error.notFound):
                self.menuBarController.render(UsageState(kind: .unauthenticated))
            case .failure(let error):
                self.menuBarController.render(UsageState(kind: .error("keychain: \(error)")))
            }
        }
    }
}
