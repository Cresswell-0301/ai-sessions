import Foundation

/// The process facts `ClaudeSource` needs, injectable so tests can count calls.
struct ClaudeProcessProbe {
    var isAlive: (Int32) -> Bool = ProcessKit.isAlive
    var startMatches: (ClaudeRegistryRecord) -> Bool? = ClaudeRegistry.startMatches
    var host: (ClaudeRegistryRecord) -> SessionHost = ClaudeRegistry.host(for:)
}

/// Claude Code sessions: the live-session registry (`<configDir>/sessions/<pid>.json`)
/// says which sessions exist and what they are doing; each session's
/// transcript adds its title and last message.
///
/// `poll` runs every second for the life of the app, so a quiet poll costs
/// one directory listing per config dir and, per record, a `stat` of it, a
/// `kill(pid, 0)` and a `stat` of its transcript. Files are read only after
/// their stamp changed.
public final class ClaudeSource: SessionSource {
    public let agent: Agent = .claude
    public let configDirs: [URL]

    /// Without a status change, a growing transcript is re-read at most this often.
    static let transcriptRefreshInterval: TimeInterval = 5
    static let maxRecordBytes = 64 * 1024
    /// A record still unparseable after this long is broken, not mid-write.
    static let unparseableReportDelay: TimeInterval = 5

    private struct RegistryFile {
        var stamp: ClaudeFileStamp
        /// The last good parse. A record caught half-written keeps this one,
        /// so its session does not flicker to "ended" for a poll.
        var record: ClaudeRegistryRecord?
        var unparseableSince: Date?
    }

    /// One process as a record describes it. A reused pid comes with another
    /// start time, hence another identity.
    private struct ProcessIdentity: Hashable {
        let pid: Int32
        let procStart: String?
        let startedAt: Double?

        init(_ record: ClaudeRegistryRecord) {
            pid = record.pid
            procStart = record.procStart
            startedAt = record.startedAt
        }
    }

    private struct HostKey: Hashable {
        let process: ProcessIdentity
        let entrypoint: String?
    }

    private struct TranscriptKey: Hashable {
        let configDir: String
        let sessionId: String
    }

    private final class TranscriptState {
        let cache: ClaudeTranscriptCache
        var refreshedAt: Date?
        var refreshedStatus: String?

        init(cache: ClaudeTranscriptCache) {
            self.cache = cache
        }
    }

    private typealias Winner = (record: ClaudeRegistryRecord, configDir: URL)

    private let log: (String) -> Void
    private let probe: ClaudeProcessProbe
    private var registryFiles: [String: RegistryFile] = [:]
    /// Set when `registryFiles` changed, so the per-process caches are pruned
    /// only then.
    private var registryChanged = false
    private var startVerdicts: [ProcessIdentity: Bool] = [:]
    private var hosts: [HostKey: SessionHost] = [:]
    private var transcripts: [TranscriptKey: TranscriptState] = [:]
    private var reported: Set<String> = []

    public convenience init(configDirs: [URL]) {
        self.init(configDirs: configDirs, log: { Log.shared.warn($0) })
    }

    init(configDirs: [URL], log: @escaping (String) -> Void, probe: ClaudeProcessProbe = ClaudeProcessProbe()) {
        self.configDirs = configDirs
        self.log = log
        self.probe = probe
    }

    public func poll(now: Date) -> [Observation] {
        var winners: [String: Winner] = [:]
        var listed = Set<String>()
        for configDir in configDirs {
            for url in registryURLs(in: configDir) {
                listed.insert(url.path)
                guard let record = record(at: url, now: now), isLive(record) else { continue }
                // Two live records for one session (a resume racing the old
                // process): the more recently written one is the truth.
                if let current = winners[record.sessionId], current.record.lastWrite >= record.lastWrite { continue }
                winners[record.sessionId] = (record, configDir)
            }
        }
        prune(listed: listed, winners: winners)
        return winners.values
            .map { observation(for: $0.record, configDir: $0.configDir, now: now) }
            .sorted { $0.key < $1.key }
    }

    // MARK: Registry

    private func registryURLs(in configDir: URL) -> [URL] {
        let directory = configDir.appending(component: "sessions", directoryHint: .isDirectory)
        do {
            return try ClaudeRegistry.listRecords(in: directory)
        } catch {
            report("list \(directory.path)", ClaudeFileIO.isNotFound(error)
                ? "Claude: no session registry at \(directory.path) (yet)"
                : "Claude: cannot list \(directory.path): \(ClaudeFileIO.describe(error))")
            return []
        }
    }

    /// The record in `url`, re-read only when the file's stamp changed.
    private func record(at url: URL, now: Date) -> ClaudeRegistryRecord? {
        let path = url.path
        let stamp: ClaudeFileStamp
        do {
            stamp = try ClaudeFileStamp(path: path)
        } catch {
            // Usually deleted since the listing: the process exited cleanly.
            if !ClaudeFileIO.isNotFound(error) {
                report("stat \(path)", "Claude: cannot stat \(path): \(ClaudeFileIO.describe(error))")
            }
            if registryFiles.removeValue(forKey: path) != nil { registryChanged = true }
            return nil
        }
        var file: RegistryFile
        if let known = registryFiles[path], known.stamp == stamp {
            file = known
        } else {
            // The stamp is taken before reading: if a write lands mid-read,
            // the next poll sees another stamp and reads again.
            file = registryFiles[path] ?? RegistryFile(stamp: stamp)
            file.stamp = stamp
            do {
                let data = try ClaudeFileIO.readSmallFile(path, limit: Self.maxRecordBytes)
                if let parsed = ClaudeRegistry.parse(data) {
                    file.record = parsed
                    file.unparseableSince = nil
                } else if file.unparseableSince == nil {
                    file.unparseableSince = now
                }
            } catch {
                if !ClaudeFileIO.isNotFound(error) {
                    report("read \(path)", "Claude: cannot read \(path): \(ClaudeFileIO.describe(error))")
                }
            }
            registryFiles[path] = file
            registryChanged = true
        }
        if let since = file.unparseableSince, now.timeIntervalSince(since) >= Self.unparseableReportDelay {
            report("parse \(path)", "Claude: \(path) is not a valid session record; "
                + (file.record == nil ? "ignoring it" : "keeping its last good contents"))
        }
        return file.record
    }

    private func isLive(_ record: ClaudeRegistryRecord) -> Bool {
        let identity = ProcessIdentity(record)
        // Every poll: the process may have exited since the last one. A verdict
        // holds only while its process lives; a crashed session's pid can later
        // come back as an unrelated process, which must be checked afresh.
        guard probe.isAlive(record.pid) else {
            startVerdicts[identity] = nil
            return false
        }
        // The start-time check (a sysctl and a date parse) has one answer per
        // process, so it runs once per identity, not once per poll.
        if let verdict = startVerdicts[identity] { return verdict }
        guard let verdict = probe.startMatches(record) else { return false }
        startVerdicts[identity] = verdict
        return verdict
    }

    private func host(for record: ClaudeRegistryRecord) -> SessionHost {
        let key = HostKey(process: ProcessIdentity(record), entrypoint: record.entrypoint)
        if let host = hosts[key] { return host }
        let host = probe.host(record)
        hosts[key] = host
        return host
    }

    // MARK: Observations

    private func observation(for record: ClaudeRegistryRecord, configDir: URL, now: Date) -> Observation {
        let transcript = transcriptInfo(for: record, configDir: configDir, now: now)
        return Observation(
            key: SessionKey(agent: .claude, id: record.sessionId),
            state: ClaudeRegistry.activityState(status: record.status),
            rawStatus: record.status,
            stateSince: record.stateSince,
            title: Self.title(record: record, transcript: transcript),
            cwd: record.cwd,
            pid: record.pid,
            entrypoint: record.entrypoint,
            lastMessage: transcript.lastAssistantText,
            host: host(for: record),
            interactive: ClaudeRegistry.isInteractive(kind: record.kind, entrypoint: record.entrypoint)
        )
    }

    /// customTitle > aiTitle > registry name > last prompt > "Claude <id prefix>".
    static func title(record: ClaudeRegistryRecord, transcript: TranscriptInfo) -> String {
        for candidate in [transcript.customTitle, transcript.aiTitle, record.name] {
            if let title = Formatting.oneLine(candidate, max: 120) { return title }
        }
        if let prompt = Formatting.oneLine(transcript.lastPrompt, max: 80) { return prompt }
        return "Claude " + record.sessionId.prefix(8)
    }

    private func transcriptInfo(for record: ClaudeRegistryRecord, configDir: URL, now: Date) -> TranscriptInfo {
        let key = TranscriptKey(configDir: configDir.path, sessionId: record.sessionId)
        let state: TranscriptState
        if let existing = transcripts[key] {
            state = existing
        } else {
            state = TranscriptState(cache: ClaudeTranscriptCache(
                sessionId: record.sessionId, configDir: configDir, cwd: record.cwd))
            transcripts[key] = state
        }
        let cache = state.cache
        guard let stamp = cache.currentStamp(now: now), stamp != cache.readStamp else { return cache.info }
        // A status flip is when the last message matters (the turn just ended),
        // so it is read at once; otherwise a growing file is read every 5 s.
        let statusChanged = state.refreshedAt != nil && state.refreshedStatus != record.status
        let due = state.refreshedAt.map { Self.elapsed(from: $0, to: now) >= Self.transcriptRefreshInterval } ?? true
        guard statusChanged || due else { return cache.info }
        do {
            try cache.refresh()
        } catch where !ClaudeFileIO.isNotFound(error) {
            let path = cache.url?.path ?? record.sessionId
            report("transcript \(path)", "Claude: cannot read transcript \(path): \(ClaudeFileIO.describe(error))")
        } catch {
            // Gone since the stat: the next poll locates it again.
        }
        state.refreshedAt = now
        state.refreshedStatus = record.status
        return cache.info
    }

    /// A clock that went backwards counts as "long ago", so nothing stalls.
    private static func elapsed(from start: Date, to now: Date) -> TimeInterval {
        let elapsed = now.timeIntervalSince(start)
        return elapsed < 0 ? .infinity : elapsed
    }

    // MARK: Housekeeping

    private func prune(listed: Set<String>, winners: [String: Winner]) {
        if registryFiles.keys.contains(where: { !listed.contains($0) }) {
            registryFiles = registryFiles.filter { listed.contains($0.key) }
            registryChanged = true
        }
        if registryChanged {
            registryChanged = false
            let identities = Set(registryFiles.values.compactMap { $0.record.map(ProcessIdentity.init) })
            startVerdicts = startVerdicts.filter { identities.contains($0.key) }
            hosts = hosts.filter { identities.contains($0.key.process) }
        }
        if transcripts.keys.contains(where: { winners[$0.sessionId]?.configDir.path != $0.configDir }) {
            transcripts = transcripts.filter { winners[$0.key.sessionId]?.configDir.path == $0.key.configDir }
        }
    }

    /// Logs a problem the first time it is seen, never once per poll.
    private func report(_ problem: String, _ message: @autoclosure () -> String) {
        guard reported.insert(problem).inserted else { return }
        log(message())
    }
}
