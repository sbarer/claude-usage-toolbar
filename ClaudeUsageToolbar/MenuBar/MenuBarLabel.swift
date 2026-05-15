import AppKit

enum MenuBarLabel {
    static let hotThreshold = 90

    static func attributedTitle(for state: UsageState) -> NSAttributedString {
        switch state.kind {
        case .loading:
            return plain("…")
        case .unauthenticated:
            return hotPill("!")
        case .error:
            return hotPill("⚠")
        case .ok(let d):
            if d.sessionPercent >= 100, let resetsAt = d.sessionResetsAt {
                let remaining = resetsAt.timeIntervalSinceNow
                if remaining > 0 {
                    return hotPill(DateUtils.formatBarCountdown(remaining))
                }
            }
            if d.sessionPercent >= hotThreshold {
                return hotPill("\(d.sessionPercent)%")
            } else {
                return plain("\(d.sessionPercent)%")
            }
        }
    }

    static func usesClaudeLogo(for state: UsageState) -> Bool {
        switch state.kind {
        case .loading, .unauthenticated, .error:
            return true
        case .ok:
            return false
        }
    }

    static func logoCountTitle(for state: UsageState) -> NSAttributedString {
        guard state.apiTriesSinceLastSuccess > 0 else {
            return plain("")
        }
        return plain("\(state.apiTriesSinceLastSuccess)")
    }

    static func isHot(_ state: UsageState) -> Bool {
        if case .ok(let d) = state.kind, d.sessionPercent >= hotThreshold {
            return true
        }
        return false
    }

    private static let centeredStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }()

    private static func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
            .paragraphStyle: centeredStyle
        ])
    }

    static let hotBackground = NSColor(red: 0.85, green: 0.24, blue: 0.12, alpha: 1)

    private static func hotPill(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: NSColor.black,
            .paragraphStyle: centeredStyle
        ])
    }
}
