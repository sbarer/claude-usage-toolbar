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
    
    // Add a timer to handle live countdown updates
    private var countdownTimer: Timer?

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
    
    deinit {
        // Invalidate the timer when the controller is deallocated
        stopCountdownTimer()
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
        
        // Logic to manage the countdown timer based on the current state
        if case .ok(let d) = state.kind,
           d.sessionPercent >= 100,
           let resetsAt = d.sessionResetsAt,
           resetsAt.timeIntervalSinceNow > 0 {
            // A countdown is needed. Start or restart the timer with the appropriate interval.
            startCountdownTimer(resetsAt: resetsAt)
        } else {
            // No countdown needed or countdown has finished. Invalidate the timer.
            stopCountdownTimer()
        }
    }

    private func updateStatusItemLength(for title: NSAttributedString) {
        updateStatusItemLength(forWidth: max(title.size().width, minimumStatusItemTitleWidth))
    }

    private func updateStatusItemLength(forWidth contentWidth: CGFloat) {
        statusItem.length = ceil(max(contentWidth, minimumStatusItemTitleWidth) + statusItemHorizontalPadding)
    }
    
    /// Calculates the time interval until the minute component of the countdown is expected to change.
    /// This is used to schedule the timer for efficient updates.
    private func timeToNextMinuteDisplayChange(from resetsAt: Date) -> TimeInterval {
        let timeRemaining = resetsAt.timeIntervalSinceNow

        // If time remaining is 0 or negative, countdown is over.
        guard timeRemaining > 0 else { return 0 }

        // Round up to the nearest second to account for fractional seconds and get the total whole seconds remaining.
        let roundedRemainingSeconds = Int(timeRemaining.rounded(.up))
        
        // Calculate seconds into the current minute (e.g., for 5m35s, this is 35).
        let secondsIntoCurrentMinute = roundedRemainingSeconds % 60
        
        // If secondsIntoCurrentMinute is 0, it means we are at an exact minute boundary (e.g., 5m00s).
        // In this case, we want the timer to fire in 60 seconds to show the next minute decrement (4m00s).
        if secondsIntoCurrentMinute == 0 {
            return 60.0
        } else {
            // If secondsIntoCurrentMinute is > 0 (e.g., 5m35s), we want the timer to fire
            // after these remaining seconds pass (in 35 seconds) to reach the 5m00s mark.
            return TimeInterval(secondsIntoCurrentMinute)
        }
    }
    
    private func startCountdownTimer(resetsAt: Date) {
        let interval = timeToNextMinuteDisplayChange(from: resetsAt)
        
        // If interval is 0, it means the countdown has already finished or is invalid
        guard interval > 0 else {
            stopCountdownTimer()
            return
        }

        // Only start a new timer if there isn't one already running with the same intended interval
        // or if the current timer is different. For simplicity, we invalidate and reschedule.
        if countdownTimer == nil || countdownTimer?.timeInterval != interval {
            NSLog("MenuBar: Scheduling countdown timer for %.0f seconds", interval)
            countdownTimer?.invalidate() // Invalidate any existing timer first
            
            countdownTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                guard let self = self, let currentState = self.currentState else {
                    self?.stopCountdownTimer()
                    return
                }
                // Re-render the current state. This call will also re-evaluate if the timer is still needed
                // and schedule the next timer with the new calculated interval.
                self.render(currentState)
            }
            // Add the timer to the main run loop to ensure it fires correctly
            RunLoop.main.add(countdownTimer!, forMode: .common)
        }
    }
    
    private func stopCountdownTimer() {
        if countdownTimer != nil {
            NSLog("MenuBar: Stopping countdown timer")
        }
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
}

