import Darwin
import Foundation

/// The tracker's memory across app restarts, kept in `<home>/state/state.json`:
/// per session, what it was doing when the app last looked and whether the
/// user has seen its latest result. This is what lets a restart announce a
/// turn that finished while the app was down without re-announcing old ones.
///
/// Not thread-safe: the `Tracker` owns it on its serial queue.
public final class StateStore {
    /// What is remembered about one session.
    public struct Record: Codable, Equatable, Sendable {
        public var state: ActivityState
        public var stateSince: Date?
        public var turnStartedAt: Date?
        /// Lets a restored unread row still say how long its turn took.
        public var lastTurnDuration: TimeInterval?
        public var unread: Bool
        /// The session stopped being reported while the app was watching, or
        /// was already gone when the app came back. Such a record still
        /// restores `unread` if the session returns, but never yields the
        /// catch-up `.finished`: its process exited (a crash, a window
        /// reload) rather than finishing a turn while the app was away.
        public var ended: Bool
        public var lastSeen: Date

        public init(state: ActivityState, stateSince: Date? = nil, turnStartedAt: Date? = nil,
                    lastTurnDuration: TimeInterval? = nil, unread: Bool = false,
                    ended: Bool = false, lastSeen: Date) {
            self.state = state
            self.stateSince = stateSince
            self.turnStartedAt = turnStartedAt
            self.lastTurnDuration = lastTurnDuration
            self.unread = unread
            self.ended = ended
            self.lastSeen = lastSeen
        }
    }

    /// Records of sessions not seen for this long are dropped.
    public static let retention: TimeInterval = 24 * 60 * 60
    /// `lastSeen` moves on every tick; on its own it is written at most this
    /// often. Retention is a day, so minutes of staleness on disk cost nothing,
    /// while a write per second forever would.
    static let lastSeenWriteInterval: TimeInterval = 5 * 60

    public let url: URL
    /// Set once a tracker has completed a tick against this store.
    public private(set) var initialized: Bool
    /// No tracker has ticked against this store yet and there was no state
    /// file to load, or only a corrupt one (see `init`). The first tick then
    /// adopts every session and announces nothing.
    public var isFirstRun: Bool { !initialized }
    public private(set) var records: [SessionKey: Record]

    /// A change worth writing now (anything but `lastSeen`).
    private var dirty = false
    /// Only `lastSeen` moved since the last write.
    private var lastSeenDirty = false
    private var lastWrite: Date?
    private var lastWriteError: String?

    /// The app's store: `<home>/state/state.json`.
    public static func standard() -> StateStore {
        StateStore(url: AppPaths.stateDir.appendingPathComponent("state.json"))
    }

    /// Loads `url`. A file that cannot be read or decoded is logged, moved
    /// aside to `<name>.corrupt` and treated as missing, so it reads as a first
    /// run: the next tick adopts every session silently. The running states
    /// and unread flags it held are lost either way, and announcing nothing
    /// beats announcing from a guess. A single unreadable record (say, a state
    /// written by a newer version) is skipped without condemning the rest.
    public init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            initialized = false
            records = [:]
            return
        }
        do {
            let file = try StateStore.decoder.decode(LenientFile.self, from: Data(contentsOf: url))
            var loaded: [SessionKey: Record] = [:]
            for (name, entry) in file.sessions {
                guard let key = SessionKey(string: name), let record = entry.value else { continue }
                loaded[key] = record
            }
            if loaded.count < file.sessions.count {
                Log.shared.warn("state.json: skipped \(file.sessions.count - loaded.count) unreadable session record(s)")
            }
            initialized = file.initialized
            records = loaded
        } catch {
            let aside = url.appendingPathExtension("corrupt")
            let moved = rename(url.path, aside.path) == 0
            Log.shared.warn("state.json is unreadable (\(error)); starting fresh as a first run"
                + (moved ? ", kept the old file as \(aside.lastPathComponent)" : ""))
            initialized = false
            records = [:]
        }
    }

    public func record(for key: SessionKey) -> Record? { records[key] }

    /// Stores the latest view of a live session.
    func update(_ record: Record, for key: SessionKey) {
        guard let old = records[key] else {
            records[key] = record
            dirty = true
            return
        }
        guard old != record else { return }
        var unchangedButSeen = old
        unchangedButSeen.lastSeen = record.lastSeen
        if unchangedButSeen == record {
            lastSeenDirty = true
        } else {
            dirty = true
        }
        records[key] = record
    }

    /// The session is no longer reported.
    func close(_ key: SessionKey) {
        guard records[key]?.ended == false else { return }
        records[key]?.ended = true
        dirty = true
    }

    /// Closes every open record except `live` (after a restart: the sessions
    /// that ended while the app was not running).
    func closeAll(except live: Set<SessionKey>) {
        for (key, record) in records where !record.ended && !live.contains(key) {
            records[key]?.ended = true
            dirty = true
        }
    }

    func clearUnread(_ key: SessionKey) {
        guard records[key]?.unread == true else { return }
        records[key]?.unread = false
        dirty = true
    }

    func clearAllUnread() {
        for (key, record) in records where record.unread {
            records[key]?.unread = false
            dirty = true
        }
    }

    func markInitialized() {
        guard !initialized else { return }
        initialized = true
        dirty = true
    }

    /// Drops records not seen within `retention` of `now`.
    public func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        for (key, record) in records where record.lastSeen < cutoff {
            records[key] = nil
            dirty = true
        }
    }

    /// Writes when something changed, or when only `lastSeen` moved and the
    /// copy on disk is older than `lastSeenWriteInterval`. A failed write is
    /// logged once per distinct error and retried on the next call.
    func saveIfNeeded(now: Date) {
        let lastSeenDue = lastSeenDirty
            && lastWrite.map { abs(now.timeIntervalSince($0)) >= Self.lastSeenWriteInterval } ?? true
        guard dirty || lastSeenDue else { return }
        do {
            try save(now: now)
            lastWriteError = nil
        } catch {
            let message = "\(error)"
            if message != lastWriteError {
                Log.shared.error("could not write \(url.path): \(message)")
            }
            lastWriteError = message
        }
    }

    /// Prunes, then writes the whole state atomically: a temp file in the same
    /// directory renamed over the old one, so a crash never leaves half a file.
    public func save(now: Date) throws {
        prune(now: now)
        var sessions: [String: Record] = [:]
        for (key, record) in records { sessions[key.description] = record }
        let data = try Self.encoder.encode(File(initialized: initialized, sessions: sessions))

        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            guard rename(temp.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        dirty = false
        lastSeenDirty = false
        lastWrite = now
    }

    // MARK: - File format

    private struct File: Encodable {
        var version = 1
        var initialized: Bool
        var sessions: [String: Record]
    }

    private struct LenientFile: Decodable {
        let initialized: Bool
        let sessions: [String: Lenient<Record>]

        private enum CodingKeys: String, CodingKey { case initialized, sessions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            initialized = try c.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
            sessions = try c.decodeIfPresent([String: Lenient<Record>].self, forKey: .sessions) ?? [:]
        }
    }

    /// Decodes to nil instead of failing the whole file.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    // Epoch seconds round-trip a Date exactly; the tracker compares restored
    // timestamps with live ones, so a lossy format (ISO 8601 truncates to the
    // millisecond) would make an unchanged state look like a new one.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
