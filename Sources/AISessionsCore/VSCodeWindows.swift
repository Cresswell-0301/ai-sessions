import Darwin
import Foundation

/// A VS Code-family editor: the URL scheme its URI handlers answer to, the
/// folder under `~/Library/Application Support` that holds its logs, and its
/// bundle id (for activating the app when there is no deep link).
public struct EditorFamily: Equatable, Sendable {
    public let appName: String
    public let urlScheme: String
    public let appSupportName: String
    public let bundleIdentifier: String?

    public init(appName: String, urlScheme: String, appSupportName: String, bundleIdentifier: String?) {
        self.appName = appName
        self.urlScheme = urlScheme
        self.appSupportName = appSupportName
        self.bundleIdentifier = bundleIdentifier
    }

    public static let vscode = EditorFamily(
        appName: "Visual Studio Code", urlScheme: "vscode",
        appSupportName: "Code", bundleIdentifier: "com.microsoft.VSCode")
    public static let vscodeInsiders = EditorFamily(
        appName: "Visual Studio Code - Insiders", urlScheme: "vscode-insiders",
        appSupportName: "Code - Insiders", bundleIdentifier: "com.microsoft.VSCodeInsiders")
    public static let cursor = EditorFamily(
        appName: "Cursor", urlScheme: "cursor",
        appSupportName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92")
    public static let windsurf = EditorFamily(
        appName: "Windsurf", urlScheme: "windsurf",
        appSupportName: "Windsurf", bundleIdentifier: "com.exafunction.windsurf")
    public static let vscodium = EditorFamily(
        appName: "VSCodium", urlScheme: "vscodium",
        appSupportName: "VSCodium", bundleIdentifier: "com.vscodium")

    public static let all: [EditorFamily] = [.vscode, .vscodeInsiders, .cursor, .windsurf, .vscodium]

    /// The family of the app bundle that contains `path`: an executable deep
    /// inside it (a helper resolves to its outermost app) or the bundle itself.
    /// Anything unrecognised is treated as VS Code, the common case.
    public static func forAppBundle(path: String) -> EditorFamily {
        guard let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else {
            return .vscode
        }
        let name = bundle.dropLast(".app".count).lowercased()
        // Most specific first: "VSCodium - Insiders" is VSCodium, not VS Code Insiders.
        if name.contains("codium") { return .vscodium }
        if name.contains("cursor") { return .cursor }
        if name.contains("windsurf") { return .windsurf }
        if name.contains("insiders") { return .vscodeInsiders }
        return .vscode
    }

    /// `~/Library/Application Support/<appSupportName>/logs`.
    public var defaultLogsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appSupportName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }
}

/// Maps a VS Code-family extension host (one per editor window, the parent of
/// a Claude process) to its window id, which `<scheme>://…?windowId=<n>` URIs
/// use to reach that window.
///
/// An instance is a snapshot of the editor's log folder: every window of the
/// newest session dirs with the pid of its latest extension host. The static
/// lookups add the primary source, the extension host's own open files.
public struct VSCodeWindowIndex: Sendable {
    public struct Window: Equatable, Sendable {
        public let id: Int
        public let extensionHostPid: Int32
        /// The logs session dir ("20260930T100702"); one per launch of the app.
        public let sessionDir: String

        public init(id: Int, extensionHostPid: Int32, sessionDir: String) {
            self.id = id
            self.extensionHostPid = extensionHostPid
            self.sessionDir = sessionDir
        }
    }

    /// Newest session dir first, then by window id.
    public let windows: [Window]

    public init(windows: [Window]) {
        self.windows = windows
    }

    /// A `code` CLI launch creates a session dir with no windows, so the live
    /// windows are not always in the newest one.
    static let maxSessionDirs = 3
    static let maxLogTailBytes: Int64 = 2 << 20

    private static let cache = Cache()

    // MARK: Snapshot

    /// Reads the newest ≤3 session dirs under `logsRoot` (default: the
    /// family's), using the last "Extension host with pid N started" line of
    /// each `window<N>/exthost/exthost.log`. Unchanged files are not re-read.
    public static func load(family: EditorFamily, logsRoot: URL? = nil) -> VSCodeWindowIndex {
        let root = (logsRoot ?? family.defaultLogsRoot).path
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else {
            return VSCodeWindowIndex(windows: [])
        }
        var windows: [Window] = []
        var visited: Set<String> = []
        for session in names.filter(isSessionDirName).sorted(by: >).prefix(maxSessionDirs) {
            let dir = root + "/" + session
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for id in entries.compactMap(windowNumber).sorted() {
                let log = "\(dir)/window\(id)/exthost/exthost.log"
                visited.insert(log)
                if let pid = cache.latestStartedPid(atPath: log) {
                    windows.append(Window(id: id, extensionHostPid: pid, sessionDir: session))
                }
            }
        }
        cache.forgetLogs(under: root + "/", except: visited)
        return VSCodeWindowIndex(windows: windows)
    }

    /// The window whose latest extension host is `pid` (newest session dir wins).
    public func windowId(forExtensionHostPid pid: Int32) -> Int? {
        windows.first { $0.extensionHostPid == pid }?.id
    }

    /// The windows of the newest session dir that has any live extension host.
    /// Only one launch of an app can be running per logs folder, so live-looking
    /// pids in older dirs can only be reused pids.
    public func liveWindows(isAlive: (Int32) -> Bool = ProcessKit.isAlive) -> [Window] {
        var checked: Set<String> = []
        for dir in windows.map(\.sessionDir) where checked.insert(dir).inserted {
            var pids: Set<Int32> = []
            let live = windows.filter {
                $0.sessionDir == dir && isAlive($0.extensionHostPid) && pids.insert($0.extensionHostPid).inserted
            }
            if !live.isEmpty { return live }
        }
        return []
    }

    // MARK: Lookups

    /// The window of the extension host `pid`: first from the window log the
    /// process holds open (works for any logs location), then from the logs.
    public static func windowId(forExtensionHostPid pid: Int32, family: EditorFamily, logsRoot: URL? = nil) -> Int? {
        if let id = windowIdFromOpenFiles(of: pid) { return id }
        return load(family: family, logsRoot: logsRoot).windowId(forExtensionHostPid: pid)
    }

    /// Number of editor windows whose latest extension host is alive.
    public static func liveWindowCount(family: EditorFamily, logsRoot: URL? = nil) -> Int {
        load(family: family, logsRoot: logsRoot).liveWindows().count
    }

    /// The extension host whose window hosts Codex thread `threadId`: the
    /// parent of the `codex` app-server that holds the thread's rollout file
    /// open. Best effort: an idle app-server may have closed it.
    public static func codexExtensionHostPid(threadId: String) -> Int32? {
        codexExtensionHostPid(threadId: threadId, executableName: "codex")
    }

    /// `executableName` is a seam for tests, which cannot run a renamed copy of
    /// a system binary (code signing kills it).
    static func codexExtensionHostPid(threadId: String, executableName: String, maxCandidates: Int = 16) -> Int32? {
        guard threadId.count >= 8, !threadId.contains("/") else { return nil }
        var candidates = 0
        for pid in OpenFiles.allPids() where pid > 1 {
            guard OpenFiles.name(of: pid) == executableName,
                  let exe = ProcessKit.path(pid), exe.hasSuffix("/" + executableName),
                  let parent = ProcessKit.info(pid)?.ppid, parent > 1,
                  // An extension host is an app's helper; a CLI codex has a shell parent.
                  let parentExe = ProcessKit.path(parent), parentExe.contains(".app/")
            else { continue }
            candidates += 1
            let holdsRollout = OpenFiles.first(in: pid) { _, path in
                path.contains("rollout-") && path.contains(threadId) ? true : nil
            } ?? false
            if holdsRollout { return parent }
            if candidates >= maxCandidates { break }
        }
        return nil
    }

    // MARK: Parsers

    /// The pid of the last "Extension host with pid N started" line: a window
    /// reload appends a new one (and an "exiting" line for the old host).
    public static func parseExtensionHostLog(_ text: String) -> Int32? {
        lastStartedPid(in: Data(text.utf8))
    }

    /// The window id in an open-file path like
    /// `…/logs/20260930T100702/window1/exthost/exthost.log`.
    public static func windowId(fromOpenPath path: String) -> Int? {
        guard path.contains("/exthost/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // logs/<session>/window<N>/exthost/<file>: "logs" needs four parts after it.
        for i in parts.indices.dropLast(4) where parts[i] == "logs" {
            if !parts[i + 1].isEmpty, parts[i + 3] == "exthost", let id = windowNumber(parts[i + 2]) {
                return id
            }
        }
        return nil
    }

    private static let startedPrefix = Data("Extension host with pid ".utf8)
    private static let startedSuffix = Data(" started".utf8)

    static func lastStartedPid(in data: Data) -> Int32? {
        var upper = data.endIndex
        while let match = data.range(of: startedPrefix, options: .backwards, in: data.startIndex..<upper) {
            if let pid = startedPid(in: data, at: match.upperBound) { return pid }
            upper = match.lowerBound
        }
        return nil
    }

    /// Digits at `index` followed by " started"; a line still being written
    /// (no suffix yet) or an "exiting" line does not count.
    private static func startedPid(in data: Data, at index: Data.Index) -> Int32? {
        var i = index
        var value: Int64 = 0
        while i < data.endIndex, i - index < 10, (0x30...0x39).contains(data[i]) {
            value = value * 10 + Int64(data[i] - 0x30)
            i += 1
        }
        guard i > index, value > 0, value <= Int64(Int32.max),
              data[i...].starts(with: startedSuffix) else { return nil }
        return Int32(value)
    }

    /// "20260930T100702": VS Code names session dirs by local launch time.
    static func isSessionDirName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 15, bytes[8] == UInt8(ascii: "T") else { return false }
        return bytes.enumerated().allSatisfy { $0.offset == 8 || (0x30...0x39).contains($0.element) }
    }

    /// "window12" → 12.
    static func windowNumber<S: StringProtocol>(_ name: S) -> Int? {
        guard name.hasPrefix("window") else { return nil }
        let digits = name.dropFirst("window".count)
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let id = Int(digits), id > 0 else { return nil }
        return id
    }

    // MARK: Open files

    private static func windowIdFromOpenFiles(of pid: Int32) -> Int? {
        // An extension host keeps its window's exthost.log open on the same fd
        // for life, so re-checking that one fd replaces a full scan.
        if let hit = cache.openLog(of: pid), OpenFiles.path(of: pid, fd: hit.fd) == hit.path {
            return hit.windowId
        }
        let found = OpenFiles.first(in: pid) { fd, path in
            windowId(fromOpenPath: path).map { OpenLog(fd: fd, path: path, windowId: $0) }
        }
        cache.setOpenLog(found, of: pid)
        return found?.windowId
    }

    struct OpenLog: Equatable {
        let fd: Int32
        let path: String
        let windowId: Int
    }

    /// Open files and process names of other processes via libproc (same user,
    /// no entitlement, no subprocess).
    enum OpenFiles {
        static let maxDescriptors = 8192

        /// Calls `body` with each open vnode (fd, path) of `pid` until it
        /// returns a value.
        static func first<T>(in pid: Int32, _ body: (Int32, String) -> T?) -> T? {
            guard pid > 0 else { return nil }
            let entrySize = MemoryLayout<proc_fdinfo>.stride
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return nil }
            // Headroom for descriptors opened between the two calls.
            let capacity = min(Int(needed) / entrySize + 32, maxDescriptors)
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let filled = fds.withUnsafeMutableBytes { buffer in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard filled > 0 else { return nil }
            for entry in fds.prefix(Int(filled) / entrySize) where entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                if let path = path(of: pid, fd: entry.proc_fd), let hit = body(entry.proc_fd, path) {
                    return hit
                }
            }
            return nil
        }

        static func path(of pid: Int32, fd: Int32) -> String? {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) > 0 else { return nil }
            return withUnsafeBytes(of: info.pvip.vip_path) { raw in
                let bytes = raw.prefix { $0 != 0 }
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
        }

        static func allPids() -> [Int32] {
            let estimate = proc_listallpids(nil, 0)
            guard estimate > 0 else { return [] }
            var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
            let count = pids.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            return count > 0 ? Array(pids.prefix(Int(count))) : []
        }

        /// The kernel's process name (the executable's file name).
        static func name(of pid: Int32) -> String? {
            var buffer = [UInt8](repeating: 0, count: 64)
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        }
    }

    // MARK: Cache

    /// Process-wide memo shared by every lookup; callers may be on any thread.
    final class Cache: @unchecked Sendable {
        private struct LogState {
            var device: Int32
            var inode: UInt64
            var size: Int64
            var mtime: timespec
            /// Offset just past the last complete line read; growth is read from here.
            var parsedUpTo: Int64
            var pid: Int32?
        }

        private let lock = NSLock()
        private var logs: [String: LogState] = [:]
        private var openLogs: [Int32: OpenLog] = [:]

        func latestStartedPid(atPath path: String) -> Int32? {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                lock.withLock { logs[path] = nil }
                return nil
            }
            let size = Int64(st.st_size)
            return lock.withLock { () -> Int32? in
                let old = logs[path]
                let sameFile = old.map { $0.device == st.st_dev && $0.inode == st.st_ino } ?? false
                if let old, sameFile, old.size == size,
                   old.mtime.tv_sec == st.st_mtimespec.tv_sec, old.mtime.tv_nsec == st.st_mtimespec.tv_nsec {
                    return old.pid
                }
                var start = max(0, size - VSCodeWindowIndex.maxLogTailBytes)
                var carried: Int32?
                if let old, sameFile, size > old.size {
                    // Appended: read only the new lines, keep the old answer if
                    // none of them is a "started" line.
                    start = max(old.parsedUpTo, start)
                    carried = old.pid
                }
                guard let data = Self.read(path, from: start, to: size) else { return nil }
                let pid = VSCodeWindowIndex.lastStartedPid(in: data) ?? carried
                let lineEnd = data.lastIndex(of: 0x0A).map { start + Int64($0 - data.startIndex) + 1 } ?? start
                logs[path] = LogState(device: st.st_dev, inode: st.st_ino, size: size,
                                      mtime: st.st_mtimespec, parsedUpTo: lineEnd, pid: pid)
                return pid
            }
        }

        func forgetLogs(under prefix: String, except keep: Set<String>) {
            lock.withLock {
                logs = logs.filter { !$0.key.hasPrefix(prefix) || keep.contains($0.key) }
            }
        }

        func openLog(of pid: Int32) -> OpenLog? {
            lock.withLock { openLogs[pid] }
        }

        func setOpenLog(_ hit: OpenLog?, of pid: Int32) {
            lock.withLock {
                openLogs[pid] = hit
                if openLogs.count > 64 {
                    openLogs = openLogs.filter { ProcessKit.isAlive($0.key) }
                }
            }
        }

        private static func read(_ path: String, from start: Int64, to end: Int64) -> Data? {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard end > start else { return Data() }
            do {
                try handle.seek(toOffset: UInt64(start))
                return try handle.read(upToCount: Int(end - start)) ?? Data()
            } catch {
                return nil
            }
        }
    }
}
