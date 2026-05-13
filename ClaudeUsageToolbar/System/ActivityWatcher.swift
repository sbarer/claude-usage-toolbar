import Foundation
import CoreServices

final class ActivityWatcher {
    private(set) var lastActivityAt: Date = .distantPast
    private var stream: FSEventStreamRef?
    private var debounceItem: DispatchWorkItem?
    private var onActivity: (() -> Void)?

    func start(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        if let mtime = mostRecentJSONLMTime() {
            lastActivityAt = mtime
        }
        let path = (NSString(string: "~/.claude/projects").expandingTildeInPath) as NSString
        let paths = [path] as CFArray
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
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onActivity?()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func mostRecentJSONLMTime() -> Date? {
        let root = (NSString(string: "~/.claude/projects").expandingTildeInPath)
        let url = URL(fileURLWithPath: root)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var newest: Date?
        for case let item as URL in e {
            guard item.pathExtension == "jsonl" else { continue }
            if let m = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if newest == nil || m > newest! { newest = m }
            }
        }
        return newest
    }
}
