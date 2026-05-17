import Foundation

enum AppConsoleLog {
    private static let maxLines = 1000
    private static let queue = DispatchQueue(label: "claude-usage-toolbar.console-log")
    private static var lines: [String] = []
    private static var pipe: Pipe?
    private static var originalStderr: Int32 = -1

    static var logFileURL: URL {
        URL(fileURLWithPath: "/Users/simonbarer/Files/ComputerScience/Projects/claude-usage-toolbar/ClaudeUsageToolbar/Logs/runningLogs")
    }

    static func initialize() {
        queue.async {
            let url = logFileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "".write(to: url, atomically: true, encoding: .utf8)
            lines = []
            startCapturing()
        }
    }

    private static func startCapturing() {
        pipe = Pipe()
        guard let pipe = pipe else { return }

        originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if originalStderr >= 0 {
                data.withUnsafeBytes { bytes in
                    _ = write(originalStderr, bytes.baseAddress, data.count)
                }
            }

            if let text = String(data: data, encoding: .utf8) {
                let newLines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                for line in newLines {
                    appendLine(line)
                }
            }
        }
    }

    private static func appendLine(_ line: String) {
        queue.async {
            let timestamp = DateUtils.logTimestampFormatter.string(from: Date())
            let message = extractMessage(from: line)
            let formattedLine = "[\(timestamp)] \(message)"

            lines.append(formattedLine)

            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }

            let content = lines.joined(separator: "\n") + "\n"
            try? content.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    private static func extractMessage(from line: String) -> String {
        // Strip NSLog boilerplate: "2026-05-15 17:12:19.693 AppName[pid:thread] "
        if let range = line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ \S+\[\d+:\d+\] "#, options: .regularExpression) {
            let message = String(line[range.upperBound...])
            return message
        }
        return line
    }

    static func ensureFileExists() -> URL {
        let url = logFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
