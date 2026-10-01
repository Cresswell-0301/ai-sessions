import Darwin
import Foundation

/// Minimal append-only file logger: `<home>/state/ai-sessions.log` (or
/// `file`), rotated to `.1` at 1 MB. Thread-safe. Also echoes to stderr when
/// `echo` is set (headless/test runs), which launchd captures for the
/// installed app.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    public var echo = false
    /// Where lines go instead of the app's log: `--headless` keeps its own,
    /// `--route` a throwaway one. Like `echo`, set it before anything logs.
    public var file: URL?
    private let queue = DispatchQueue(label: "ai-sessions.log")
    private let maxBytes = 1_000_000
    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public var fileURL: URL { file ?? AppPaths.stateDir.appendingPathComponent("ai-sessions.log") }

    public func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    public func warn(_ message: @autoclosure () -> String) { write("WARN", message()) }
    public func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    private func write(_ level: String, _ message: String) {
        let now = Date()
        // Resolved now, not when the queue gets to it: the line belongs to the
        // home in effect when it was logged. (Tests point AI_SESSIONS_HOME at
        // a scratch dir and restore it in tearDown, before the queue drains.)
        let url = fileURL
        queue.async { [self] in
            // One entry, one line, and nothing a terminal would act on:
            // messages carry session titles, and `--headless` echoes them to
            // one. A newline in a message cannot forge a second entry either.
            let text = Formatting.withoutControlCharacters(message)
            let line = "\(formatter.string(from: now)) \(level) \(text)\n"
            if echo { FileHandle.standardError.write(Data(line.utf8)) }
            append(line, to: url)
        }
    }

    /// O_APPEND moves to the end and writes in one step, so two processes on
    /// one log (the app and `--headless --use-app-state`, a dev build) never
    /// write over each other's lines, as seek-then-write did. New files are
    /// 0600: a log holds titles copied out of ~/.claude.
    private func append(_ line: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        if rotateIfFull(fd, path: url.path) {
            close(fd)
            fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
        }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// Past `maxBytes`, the file `fd` has open moves to `.1`, replacing the
    /// older one. Under an exclusive lock, and only while `path` still names
    /// that file: another process that saw the same full file finds it moved
    /// and must not move the fresh one over the history just kept. True when
    /// `path` no longer names `fd`'s file, so the caller reopens it.
    private func rotateIfFull(_ fd: Int32, path: String) -> Bool {
        var held = stat()
        guard fstat(fd, &held) == 0, held.st_size > maxBytes, flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        var named = stat()
        guard stat(path, &named) == 0, named.st_ino == held.st_ino, named.st_dev == held.st_dev else {
            return true // rotated by another process meanwhile
        }
        return rename(path, path + ".1") == 0
    }

    /// Blocks until queued lines are written (tests, shutdown).
    public func flush() { queue.sync {} }
}
