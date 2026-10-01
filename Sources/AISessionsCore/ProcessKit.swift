import Darwin
import Foundation

/// Facts about one process, read with sysctl (no subprocess, no permissions).
public struct ProcInfo: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let startTime: Date
    /// Short command name (p_comm, max 16 chars).
    public let comm: String
}

/// Process inspection helpers used for liveness checks and host discovery.
public enum ProcessKit {
    /// True if a process with this pid exists (even if owned by another user).
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public static func info(_ pid: Int32) -> ProcInfo? {
        guard pid > 0 else { return nil }
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, 4, &kinfo, &size, nil, 0)
        }
        guard rc == 0, size > 0, kinfo.kp_proc.p_pid == pid else { return nil }
        let tv = kinfo.kp_proc.p_starttime
        let start = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
        let comm = withUnsafePointer(to: kinfo.kp_proc.p_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return ProcInfo(pid: pid, ppid: kinfo.kp_eproc.e_ppid, startTime: start, comm: comm)
    }

    /// Full executable path (proc_pidpath), e.g. ".../Visual Studio Code.app/Contents/MacOS/Code".
    public static func path(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The parent chain of `pid`, nearest first, excluding `pid` itself and launchd.
    public static func ancestors(of pid: Int32, limit: Int = 32) -> [ProcInfo] {
        var result: [ProcInfo] = []
        var current = info(pid)?.ppid ?? 0
        while current > 1, result.count < limit, let p = info(current) {
            result.append(p)
            if p.ppid == current { break }
            current = p.ppid
        }
        return result
    }

    /// The `.app` bundle path that contains `executablePath`, if any
    /// (outermost bundle, so helper apps resolve to their parent app).
    public static func appBundlePath(forExecutable executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }

    /// Claude's registry `procStart` uses the C `asctime` layout in UTC, e.g.
    /// "Thu Oct  1 02:59:07 2026". Returns nil if it cannot be parsed.
    public static func parseProcStart(_ text: String) -> Date? {
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: collapsed)
    }

    /// True when the live process `pid` is the same process that wrote a
    /// registry record with this `procStart` (defeats pid reuse). Accepts the
    /// text as UTC or local time, with a 2 s tolerance. Unparseable → true
    /// (fall back to plain liveness rather than dropping a real session).
    public static func matchesProcStart(_ pid: Int32, procStart: String?) -> Bool {
        guard let procStart, !procStart.isEmpty else { return true }
        guard let live = info(pid)?.startTime else { return false }
        guard let utc = parseProcStart(procStart) else { return true }
        if abs(utc.timeIntervalSince(live)) <= 2 { return true }
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: utc))
        return abs(utc.addingTimeInterval(-offset).timeIntervalSince(live)) <= 2
    }
}
