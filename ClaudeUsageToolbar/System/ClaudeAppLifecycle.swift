import Foundation
import AppKit

final class ClaudeAppLifecycle {
    private let bundleId = "com.anthropic.claudefordesktop"
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private let onClaudeQuit: () -> Void

    init(onClaudeQuit: @escaping () -> Void) {
        self.onClaudeQuit = onClaudeQuit
        let nc = NSWorkspace.shared.notificationCenter
        launchObserver = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { _ in /* nothing — we only care about termination here */ }

        terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == self.bundleId {
                self.onClaudeQuit()
            }
        }
    }

    var isClaudeRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let o = launchObserver { nc.removeObserver(o) }
        if let o = terminateObserver { nc.removeObserver(o) }
    }
}
