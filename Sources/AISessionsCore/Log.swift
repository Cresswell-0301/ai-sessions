import Foundation

/// Minimal append-only file logger: `<home>/state/ai-sessions.log`, rotated to
/// `.1` at 1 MB. Thread-safe. Also echoes to stderr when `echo` is set
/// (headless/test runs), which launchd captures for the installed app.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    public var echo = false
    private let queue = DispatchQueue(label: "ai-sessions.log")
    private let maxBytes = 1_000_000
    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public var fileURL: URL { AppPaths.stateDir.appendingPathComponent("ai-sessions.log") }

    public func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    public func warn(_ message: @autoclosure () -> String) { write("WARN", message()) }
    public func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    private func write(_ level: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: now)) \(level) \(message)\n"
            if echo { FileHandle.standardError.write(Data(line.utf8)) }
            let url = fileURL
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
                let rotated = url.appendingPathExtension("1")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Blocks until queued lines are written (tests, shutdown).
    public func flush() { queue.sync {} }
}
