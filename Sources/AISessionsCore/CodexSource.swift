import Darwin
import Foundation
import SQLite3

/// Codex threads, from `<home>/sessions/YYYY/MM/DD/rollout-*.jsonl`, titled
/// from Codex's own thread index.
///
/// Discovery runs at most every 10 s: the day directories covering the
/// recency window (local calendar, yesterday included), plus the threads the
/// state DB says were updated within it. The DB matters because a resumed
/// thread keeps appending to the rollout in the directory of the day it was
/// created (real rollouts from 08/12 were written on 08/25), and the DB's
/// `updated_at` follows the rollout's mtime to the second. Every poll stats
/// the tracked rollouts and reads only what they gained.
public final class CodexSource: SessionSource {
    public let agent: Agent = .codex
    public let homes: [URL]
    public let recentHours: Double

    static let rescanInterval: TimeInterval = 10
    static let missingTitleRetry: TimeInterval = 30
    /// Found titles are re-read now and then; a rename also lands in
    /// `session_index.jsonl`, whose change refreshes them at once.
    static let titleRefreshInterval: TimeInterval = 120
    static let maxScanDays = 31

    /// Where discovery and drops are logged; tests silence it.
    var logger: (String) -> Void = { Log.shared.info($0) }
    /// Rollouts being followed, ready or not.
    var trackedRolloutCount: Int { rollouts.count }

    private var rollouts: [String: TrackedRollout] = [:]
    private var indexes: [CodexSessionIndex]
    private var databaseFailureLogged: [Bool]
    private var titles: [String: StoredTitle] = [:]
    private var titleMemo: [String: (inputs: TitleInputs, title: String)] = [:]
    private var lastScan: Date?

    public init(homes: [URL], recentHours: Double) {
        self.homes = homes
        self.recentHours = recentHours
        indexes = homes.map { _ in CodexSessionIndex() }
        databaseFailureLogged = homes.map { _ in false }
    }

    /// A thread is reported while its rollout changed within `recentHours`, or
    /// while it is running or waiting, and dropped afterwards.
    public func poll(now: Date) -> [Observation] {
        let cutoff = now.addingTimeInterval(-recentHours * 3600)
        var databases: [Int: CodexStateDB?] = [:]
        defer { databases.values.forEach { $0?.close() } }

        if lastScan.map({ now.timeIntervalSince($0) >= Self.rescanInterval || now < $0 }) ?? true {
            lastScan = now
            rescan(now: now, cutoff: cutoff, databases: &databases)
        }

        var live: [(rollout: TrackedRollout, meta: CodexSessionMeta)] = []
        for (path, rollout) in rollouts {
            let reader = rollout.reader
            if reader.update() == .missing {
                forget(path, because: "its rollout is gone")
                continue
            }
            let recent = (reader.modifiedAt ?? .distantPast) >= cutoff
            guard let meta = reader.meta else {
                // Not a readable rollout (yet): give up once it goes quiet.
                if !recent { forget(path, because: "it never became readable") }
                continue
            }
            guard recent || reader.state != .idle else {
                forget(path, because: "it has been idle for \(Formatting.duration(recentHours * 3600))")
                continue
            }
            if !rollout.announced {
                rollouts[path]?.announced = true
                logger("codex: tracking \(meta.id) (\(meta.originator ?? "?"), \(meta.sourceKind)) \(reader.state.rawValue)")
            }
            live.append((rollout, meta))
        }

        refreshTitles(of: live, now: now, databases: &databases)

        var newest: [String: (observation: Observation, modified: Date)] = [:]
        for (rollout, meta) in live {
            let reader = rollout.reader
            let modified = reader.modifiedAt ?? .distantPast
            if let other = newest[meta.id], other.modified >= modified { continue }
            let observation = Observation(
                key: SessionKey(agent: .codex, id: meta.id),
                state: reader.state,
                rawStatus: reader.rawStatus,
                stateSince: reader.stateSince,
                title: title(for: meta.id, reader: reader, home: rollout.home),
                cwd: meta.cwd,
                entrypoint: meta.originator,
                lastMessage: reader.lastMessage,
                host: meta.host,
                interactive: meta.isInteractive)
            newest[meta.id] = (observation, modified)
        }
        return newest.values.map(\.observation).sorted { $0.key < $1.key }
    }

    // MARK: Discovery

    private func rescan(now: Date, cutoff: Date, databases: inout [Int: CodexStateDB?]) {
        for home in homes.indices {
            let root = homes[home]
            if indexes[home].refresh(path: root.appendingPathComponent("session_index.jsonl").path) {
                // A rename lands in both the index and the DB.
                titles.removeAll()
            }
            guard let sessions = Self.canonicalPath(root.appendingPathComponent("sessions").path) else { continue }
            var candidates = Set<String>()
            for directory in Self.dayDirectories(sessionsRoot: sessions, now: now, cutoff: cutoff) {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
                for name in names where Self.isRolloutName(name) {
                    candidates.insert(directory + "/" + name)
                }
            }
            if let database = database(for: home, in: &databases) {
                for path in database.rolloutPaths(updatedSince: cutoff) {
                    // Only rollouts under this home's sessions/ directory.
                    guard Self.isRolloutName((path as NSString).lastPathComponent),
                          let real = Self.canonicalPath(path), real.hasPrefix(sessions + "/") else { continue }
                    candidates.insert(real)
                }
            }
            for path in candidates where rollouts[path] == nil {
                guard let modified = Self.modificationDate(path), modified >= cutoff else { continue }
                rollouts[path] = TrackedRollout(reader: CodexRolloutReader(url: URL(fileURLWithPath: path)), home: home)
            }
        }
    }

    private func forget(_ path: String, because reason: String) {
        guard let rollout = rollouts.removeValue(forKey: path) else { return }
        guard let id = rollout.reader.meta?.id else { return }
        if rollout.announced { logger("codex: dropped \(id): \(reason)") }
        if !rollouts.values.contains(where: { $0.reader.meta?.id == id }) {
            titles[id] = nil
            titleMemo[id] = nil
        }
    }

    /// `<sessionsRoot>/YYYY/MM/DD` for each local day from the start of the
    /// window (or yesterday, if earlier) through today; at most `maxScanDays`.
    static func dayDirectories(sessionsRoot: String, now: Date, cutoff: Date,
                               calendar: Calendar = .current) -> [String] {
        let earliest = max(min(cutoff, now.addingTimeInterval(-86_400)),
                           now.addingTimeInterval(-Double(maxScanDays - 1) * 86_400))
        var day = calendar.startOfDay(for: earliest)
        let today = calendar.startOfDay(for: now)
        var directories: [String] = []
        while day <= today, directories.count < maxScanDays {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { break }
            directories.append("\(sessionsRoot)/\(pad(year, 4))/\(pad(month, 2))/\(pad(dayOfMonth, 2))")
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return directories
    }

    static func isRolloutName(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return CodexRolloutReader.date(st.st_mtimespec)
    }

    // MARK: Titles

    /// Opens a home's newest state DB at most once per poll; `poll` closes it.
    private func database(for home: Int, in databases: inout [Int: CodexStateDB?]) -> CodexStateDB? {
        if let opened = databases[home] { return opened }
        var database: CodexStateDB?
        if let path = CodexStateDB.newestPath(in: homes[home]) {
            switch CodexStateDB.open(path: path) {
            case .success(let opened):
                database = opened
                databaseFailureLogged[home] = false
            case .failure(let error):
                if !databaseFailureLogged[home] {
                    databaseFailureLogged[home] = true
                    logger("codex: cannot read \(path): \(error.message)")
                }
            }
        }
        databases[home] = database
        return database
    }

    private func refreshTitles(of live: [(rollout: TrackedRollout, meta: CodexSessionMeta)], now: Date,
                               databases: inout [Int: CodexStateDB?]) {
        for (rollout, meta) in live {
            if let stored = titles[meta.id] {
                let age = now.timeIntervalSince(stored.checkedAt)
                let interval = stored.isMissing ? Self.missingTitleRetry : Self.titleRefreshInterval
                if age >= 0, age < interval { continue }
            }
            let names = database(for: rollout.home, in: &databases)?.names(ofThread: meta.id)
            titles[meta.id] = StoredTitle(name: names?.name, title: names?.title, checkedAt: now)
        }
    }

    private func title(for id: String, reader: CodexRolloutReader, home: Int) -> String {
        let stored = titles[id]
        let inputs = TitleInputs(name: stored?.name, indexName: indexes[home].names[id],
                                 storedTitle: stored?.title, firstUserMessage: reader.firstUserMessage)
        if let memo = titleMemo[id], memo.inputs == inputs { return memo.title }
        let title = Self.title(name: inputs.name, indexName: inputs.indexName, storedTitle: inputs.storedTitle,
                               firstUserMessage: inputs.firstUserMessage, id: id)
        titleMemo[id] = (inputs, title)
        return title
    }

    /// Thread name (the user's rename, or Codex's generated name) > the
    /// session index's latest name > the DB title (older builds stored the
    /// raw first prompt there) > the first prompt > "Codex " + short id.
    static func title(name: String?, indexName: String?, storedTitle: String?, firstUserMessage: String?,
                      id: String) -> String {
        if let title = Formatting.oneLine(name, max: 120) { return title }
        if let title = Formatting.oneLine(indexName, max: 120) { return title }
        if let title = Formatting.oneLine(storedTitle.flatMap(CodexText.titleText), max: 80) { return title }
        if let title = Formatting.oneLine(firstUserMessage, max: 80) { return title }
        return "Codex " + String(id.prefix(8))
    }

    private struct TrackedRollout {
        let reader: CodexRolloutReader
        let home: Int
        var announced = false
    }

    private struct StoredTitle {
        var name: String?
        var title: String?
        var checkedAt: Date

        var isMissing: Bool { (name ?? "").isEmpty && (title ?? "").isEmpty }
    }

    private struct TitleInputs: Equatable {
        var name: String?
        var indexName: String?
        var storedTitle: String?
        var firstUserMessage: String?
    }
}

// MARK: - State DB

/// Codex's thread index, `<home>/state_<N>.sqlite`. Codex writes it
/// concurrently (WAL), so it is opened read-only for one poll and closed.
final class CodexStateDB {
    struct OpenError: Error {
        let message: String
    }

    private var handle: OpaquePointer?
    private var titleStatement: OpaquePointer?
    private var titleHasName = false
    private var titlePrepared = false

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        close()
    }

    /// The highest-numbered `state_<N>.sqlite` in `home`.
    static func newestPath(in home: URL) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.path) else { return nil }
        var newest: (version: Int, name: String)?
        for name in names where name.hasPrefix("state_") && name.hasSuffix(".sqlite") {
            let digits = name.dropFirst("state_".count).dropLast(".sqlite".count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let version = Int(digits) else { continue }
            if newest.map({ version > $0.version }) ?? true { newest = (version, name) }
        }
        return newest.map { home.appendingPathComponent($0.name).path }
    }

    static func open(path: String) -> Result<CodexStateDB, OpenError> {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2("file:" + uriPath(path) + "?mode=ro", &handle,
                                 SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "error \(rc)"
            sqlite3_close(handle)
            return .failure(OpenError(message: message))
        }
        sqlite3_busy_timeout(handle, 200)
        return .success(CodexStateDB(handle: handle))
    }

    func close() {
        sqlite3_finalize(titleStatement)
        titleStatement = nil
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    /// The thread's `name` (absent from older schemas) and `title`; nil when
    /// there is no row or the DB is busy.
    func names(ofThread id: String) -> (name: String?, title: String?)? {
        guard let statement = prepareTitleStatement() else { return nil }
        return id.withCString { cId -> (name: String?, title: String?)? in
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            guard sqlite3_bind_text(statement, 1, cId, -1, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return nil }
            if titleHasName { return (Self.text(statement, 0), Self.text(statement, 1)) }
            return (nil, Self.text(statement, 0))
        }
    }

    /// Rollout paths of the unarchived threads updated since `date`.
    func rolloutPaths(updatedSince date: Date) -> [String] {
        guard let handle else { return [] }
        let since = Int64(date.timeIntervalSince1970.rounded(.down))
        for sql in ["SELECT rollout_path FROM threads WHERE updated_at >= ? AND archived = 0",
                    "SELECT rollout_path FROM threads WHERE updated_at >= ?"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                continue
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, since)
            var paths: [String] = []
            while paths.count < 1000, sqlite3_step(statement) == SQLITE_ROW {
                if let path = Self.text(statement, 0), !path.isEmpty { paths.append(path) }
            }
            return paths
        }
        return []
    }

    private func prepareTitleStatement() -> OpaquePointer? {
        if titlePrepared { return titleStatement }
        titlePrepared = true
        guard let handle else { return nil }
        for (sql, hasName) in [("SELECT name, title FROM threads WHERE id = ?", true),
                               ("SELECT title FROM threads WHERE id = ?", false)] {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement {
                titleStatement = statement
                titleHasName = hasName
                return statement
            }
            sqlite3_finalize(statement)
        }
        return nil
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    /// SQLite decodes %HH in a `file:` URI path; '?', '#' and '%' would end or corrupt it.
    private static func uriPath(_ path: String) -> String {
        var result = ""
        for byte in path.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "/"), UInt8(ascii: "."),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                result += String(format: "%%%02X", UInt32(byte))
            }
        }
        return result
    }
}

// MARK: - Session index

/// `<home>/session_index.jsonl`: one `{"id","thread_name","updated_at"}`
/// line each time a thread is named; the latest line per id wins.
struct CodexSessionIndex {
    static let maxBytes: Int64 = 4 << 20

    private(set) var names: [String: String] = [:]
    private var stamp: Stamp?

    /// Re-reads the file when it changed. True when a name changed.
    mutating func refresh(path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            stamp = nil
            guard !names.isEmpty else { return false }
            names = [:]
            return true
        }
        let current = Stamp(st)
        guard current != stamp else { return false }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let size = Int64(st.st_size)
        let start = max(0, size - Self.maxBytes)
        guard let data = CodexBytes.read(fd, at: start, count: Int(size - start)) else { return false }
        stamp = current
        var body = data[...]
        if start > 0, let newline = CodexBytes.newline(in: data, from: data.startIndex) {
            body = data[(newline + 1)...]
        }
        let parsed = Self.parse(body)
        guard parsed != names else { return false }
        names = parsed
        return true
    }

    static func parse(_ data: Data) -> [String: String] {
        var names: [String: String] = [:]
        let end = CodexBytes.forEachLine(in: data) { line in
            apply(line, to: &names)
            return true
        }
        if end < data.endIndex { apply(data[end...], to: &names) }
        return names
    }

    private static func apply(_ line: Data, to names: inout [String: String]) {
        guard let object = CodexLine.object(line), let id = object["id"] as? String, !id.isEmpty,
              let name = object["thread_name"] as? String else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = trimmed.isEmpty ? nil : trimmed
    }

    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int

        init(_ st: stat) {
            device = st.st_dev
            inode = st.st_ino
            size = st.st_size
            seconds = st.st_mtimespec.tv_sec
            nanoseconds = st.st_mtimespec.tv_nsec
        }
    }
}
