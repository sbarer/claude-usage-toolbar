import Foundation

enum UsageAPIDebugLog {
    enum RetrySource {
        case response
        case fallback

        var description: String {
            switch self {
            case .response: "from response"
            case .fallback: "fallback value"
            }
        }
    }

    private struct Entry {
        let body: String
        let retryAfter: TimeInterval?
        let retrySource: RetrySource?
    }

    private static let maxEntries = 20
    private static let queue = DispatchQueue(label: "claude-usage-toolbar.api-debug-log")
    private static var entries: [Entry] = []

    static var fileURL: URL { LocalPaths.apiDebugLogFileURL }

    static func record(
        _ lines: [String],
        rateLimitRetryAfter: TimeInterval? = nil,
        rateLimitRetrySource: RetrySource? = nil
    ) {
        let entry = Entry(
            body: lines.joined(separator: "\n"),
            retryAfter: rateLimitRetryAfter,
            retrySource: rateLimitRetrySource
        )
        queue.async {
            entries.append(entry)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            writeEntries()
        }
    }

    static func ensureFileExists() -> URL {
        queue.sync {
            writeEntries()
            return fileURL
        }
    }

    private static func writeEntries() {
        let url = fileURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let body: String
        if entries.isEmpty {
            body = "No usage API calls recorded yet.\n"
        } else {
            body = entries.reversed().enumerated()
                .map { index, entry in
                    var header = "Call \(index + 1)"
                    if let retryAfter = entry.retryAfter, let retrySource = entry.retrySource {
                        header += "\nnew retry time: \(DateUtils.formatRetryInterval(retryAfter)) (\(retrySource.description))"
                    }
                    return "\(header)\n\(entry.body)"
                }
                .joined(separator: "\n\n---\n\n") + "\n"
        }
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

}
