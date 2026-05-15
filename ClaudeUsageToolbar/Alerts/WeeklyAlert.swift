import AppKit
import Foundation

enum WeeklyAlert {
    static func show(percent: Int, resetsAt: Date) {
        let alert = NSAlert()
        alert.messageText = "Claude weekly usage is at \(percent)%"

        let absolute = DateUtils.fullDateFormatter.string(from: resetsAt)
        let relative = DateUtils.relativeDescription(to: resetsAt)
        alert.informativeText = "Weekly limit resets \(absolute)\n(\(relative))"
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.Menu.ok)
        alert.addButton(withTitle: Strings.Menu.openClaude)

        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            ClaudeUsageOpener.open()
        }
    }
}
