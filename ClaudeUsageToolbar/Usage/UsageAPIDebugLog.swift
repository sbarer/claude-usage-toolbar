import Foundation

enum UsageAPIDebugLog {
    private static let maxEntries = 5
    private static let queue = DispatchQueue(label: "claude-usage-toolbar.api-debug-log")
    private static var entries: [String] = []

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("ClaudeUsageToolbar", isDirectory: true)
            .appendingPathComponent("recent-usage-calls.txt")
    }

    static func record(_ lines: [String]) {
        let entry = lines.joined(separator: "\n")
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
            body = entries.enumerated()
                .map { index, entry in "Call \(index + 1)\n\(entry)" }
                .joined(separator: "\n\n---\n\n") + "\n"
        }
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}
