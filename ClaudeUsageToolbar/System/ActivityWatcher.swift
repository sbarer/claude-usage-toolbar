import Foundation
import CoreServices

final class ActivityWatcher {
    private(set) var lastActivityAt: Date = .distantPast
    private var stream: FSEventStreamRef?
    private var debounceItem: DispatchWorkItem?
    private var onActivity: (() -> Void)?

    private static let watchedPaths: [String] = [
        (NSString(string: "~/.claude/projects").expandingTildeInPath),
        (NSString(string: "~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig").expandingTildeInPath),
        (NSString(string: "~/.vscode/globalStorage/anthropic.claude-code").expandingTildeInPath)
    ]

    func start(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        NSLog("ActivityWatcher: starting, watching %d paths", Self.watchedPaths.count)
        for path in Self.watchedPaths {
            NSLog("ActivityWatcher:   %@", path)
        }
        if let mtime = mostRecentJSONLMTime() {
            lastActivityAt = mtime
            NSLog("ActivityWatcher: initial lastActivityAt=%@ (%.0fs ago)", "\(mtime)", -mtime.timeIntervalSinceNow)
        } else {
            NSLog("ActivityWatcher: no JSONL files found, lastActivityAt=distantPast")
        }
        let paths = Self.watchedPaths.map { $0 as NSString } as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let me = Unmanaged<ActivityWatcher>.fromOpaque(info).takeUnretainedValue()
                me.handleEvent()
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func handleEvent() {
        lastActivityAt = Date()
        NSLog("ActivityWatcher: FS event detected, debouncing 5s")
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            NSLog("ActivityWatcher: debounce elapsed, firing onActivity")
            self?.onActivity?()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func mostRecentJSONLMTime() -> Date? {
        var newest: Date?
        for root in Self.watchedPaths {
            let url = URL(fileURLWithPath: root)
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let item as URL in e {
                guard item.pathExtension == "jsonl" else { continue }
                if let m = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    if newest == nil || m > newest! { newest = m }
                }
            }
        }
        return newest
    }
}
