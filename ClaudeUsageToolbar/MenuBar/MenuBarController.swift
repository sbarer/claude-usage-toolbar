import AppKit

final class MenuBarController {
    private let statusItemHorizontalPadding: CGFloat = 12
    private let statusItemImageWidth: CGFloat = 18
    private let statusItemImageTitleSpacing: CGFloat = 4
    private let minimumStatusItemTitleWidth = NSAttributedString(
        string: "...",
        attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
    ).size().width
    private let statusItem: NSStatusItem
    private(set) var currentState: UsageState?
    private let onLeftClick: () -> Void
    private let onOptionClick: () -> Void

    private lazy var claudeLogoImage: NSImage? = {
        guard let image = NSImage(named: "claude-logo")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: statusItemImageWidth, height: statusItemImageWidth)
        image.isTemplate = false
        return image
    }()

    init(onLeftClick: @escaping () -> Void, onOptionClick: @escaping () -> Void) {
        self.onLeftClick = onLeftClick
        self.onOptionClick = onOptionClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: Any?) {
        if NSEvent.modifierFlags.contains(.option) {
            NSLog("MenuBar: option-clicked")
            onOptionClick()
        } else {
            NSLog("MenuBar: regular clicked")
            onLeftClick()
        }
    }

    func showMenu(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func render(_ state: UsageState) {
        guard let button = statusItem.button else { return }
        NSLog("MenuBar: rendering state=%@", state.debugDescription)
        currentState = state
        button.toolTip = state.tooltip
        button.alignment = .center
        button.wantsLayer = true
        button.layer?.cornerRadius = 10

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
        updateStatusItemLength(forWidth: max(title.size().width, minimumStatusItemTitleWidth))
    }

    private func updateStatusItemLength(forWidth contentWidth: CGFloat) {
        statusItem.length = ceil(max(contentWidth, minimumStatusItemTitleWidth) + statusItemHorizontalPadding)
    }
}
