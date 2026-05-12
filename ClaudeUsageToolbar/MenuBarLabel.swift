import AppKit

enum MenuBarLabel {
    static let hotThreshold = 90

    static func attributedTitle(for state: UsageState) -> NSAttributedString {
        switch state.kind {
        case .loading:
            return plain("…")
        case .unauthenticated:
            return plain("!")
        case .error:
            return plain("⚠")
        case .ok(let session, _, _, _):
            let text = " \(session)% "
            if session >= hotThreshold {
                return hotPill(text)
            } else {
                return plain(text)
            }
        }
    }

    private static func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0)
        ])
    }

    private static func hotPill(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
            .backgroundColor: NSColor.systemRed,
            .foregroundColor: NSColor.white
        ])
    }
}
