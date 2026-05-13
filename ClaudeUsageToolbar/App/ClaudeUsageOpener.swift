import AppKit

enum ClaudeUsageOpener {
    static func open() {
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
