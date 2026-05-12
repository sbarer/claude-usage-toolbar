import AppKit
import Foundation

enum WeeklyAlert {
    static func show(percent: Int, resetsAt: Date) {
        let alert = NSAlert()
        alert.messageText = "Claude weekly usage is at \(percent)%"

        let absolute = absoluteFormatter.string(from: resetsAt)
        let relative = relativeString(to: resetsAt)
        alert.informativeText = "Weekly limit resets \(absolute)\n(\(relative))"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Claude")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "claude://usage") {
                NSWorkspace.shared.open(url)
            }
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: cfg, completionHandler: nil)
            }
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    private static func relativeString(to date: Date) -> String {
        let now = Date()
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "any moment now" }
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if days >= 1 { return "in \(days)d \(hours)h" }
        if hours >= 1 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }
}
