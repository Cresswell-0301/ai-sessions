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
    /// …and this often while the session is busy: an answer given while
    /// background work keeps the record "busy" shows only in the transcript.
    static let busyTranscriptRefreshInterval: TimeInterval = 2
    /// The raw status of a session that has answered while its background
    /// work (agents, workflows, shells) still keeps the record busy.
    public static let answeredWhileBusy = "busy:background"
    /// Claude writes a turn's last transcript entry ~200 ms before its record
    /// flips busy → idle. A flip seen before the transcript shows how the
    /// turn ended is held as running for at most this long, the transcript
    /// re-read every poll, before it counts as a completed turn: an Esc whose
    /// marker lands late must not be announced as "done".
    static let transcriptLagAllowance: TimeInterval = 2
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

    /// One session as the source follows it: its transcript, and what the
    /// previous poll reported.
    private final class FollowedSession {
        let cache: ClaudeTranscriptCache
        var refreshedAt: Date?
        var refreshedStatus: String?
        /// Lets a dialog over a turn, or a transcript that lags the registry,
        /// keep the turn running.
        var lastReport: Report?
        /// The first poll that saw busy → idle before the transcript showed
        /// how the turn ended.
        var flipSeenAt: Date?

        init(cache: ClaudeTranscriptCache) {
            self.cache = cache
        }
    }

    /// The state part of an observation, and the process it came from.
    private struct Report {
        var state: ActivityState
        var rawStatus: String?
        var stateSince: Date?
        var pid: Int32
        var procStart: String?
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
    private var followed: [TranscriptKey: FollowedSession] = [:]
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
        let session = followedSession(for: record, configDir: configDir)
        let previous = session.lastReport
        var report = Report(state: ClaudeRegistry.activityState(status: record.status, waitingFor: record.waitingFor),
                            rawStatus: ClaudeRegistry.rawStatus(status: record.status, waitingFor: record.waitingFor),
                            stateSince: record.stateSince, pid: record.pid, procStart: record.procStart)
        // The record left busy, or shows a dialog over the turn: whether and
        // how the turn ended is in the transcript, read now and every poll
        // until it says.
        let turnMayHaveEnded = report.state == .idle && previous?.state == .running
        let transcript = transcriptInfo(of: session, record: record, now: now, urgent: turnMayHaveEnded)
        var turnEnd: TurnEnd?
        if record.status == "busy", report.state == .running {
            // Claude keeps the record busy while background work it started
            // runs, even after answering. A transcript resting on this turn's
            // end means it has answered: that is the "done" worth announcing.
            session.flipSeenAt = nil
            // Only a dated answer from inside this busy stretch counts: an
            // undated one could be the previous turn's, and announcing it would
            // be a false "done" (the record cannot tell; the transcript must).
            if let resting = transcript.restingTurnEnd, let answeredAt = resting.at,
               let busySince = report.stateSince, answeredAt >= busySince {
                report.state = .idle
                report.rawStatus = Self.answeredWhileBusy
                report.stateSince = answeredAt
                turnEnd = resting.kind
            } else if let started = transcript.turnStartedAt, let since = report.stateSince, started > since {
                // A later turn of the same busy stretch (background work woke
                // Claude up): time it from its own first message.
                report.stateSince = started
            }
        } else if turnMayHaveEnded, let previous {
            (report, turnEnd) = endOfTurn(report, after: previous, record: record, transcript: transcript,
                                          session: session, now: now)
        } else {
            session.flipSeenAt = nil
            if report.state == .idle { turnEnd = transcript.lastTurnEnd?.kind }
        }
        session.lastReport = report
        return Observation(
            key: SessionKey(agent: .claude, id: record.sessionId),
            state: report.state,
            rawStatus: report.rawStatus,
            stateSince: report.stateSince,
            title: Self.title(record: record, transcript: transcript),
            cwd: record.cwd,
            pid: record.pid,
            entrypoint: record.entrypoint,
            lastMessage: transcript.lastAssistantText,
            host: host(for: record),
            interactive: ClaudeRegistry.isInteractive(kind: record.kind, entrypoint: record.entrypoint),
            procStart: record.procStart,
            turnEnd: turnEnd
        )
    }

    /// busy → idle, or a dialog opened over a running turn. The turn ended
    /// if the transcript's newest turn-ending entry (an "end_turn" answer or
    /// the Esc marker) is not older than the turn's start. Without one, a
    /// dialog keeps the turn running (it can open mid-turn), and a plain flip
    /// is held as running for `transcriptLagAllowance` before it counts as
    /// completed (the entry may still be on its way to disk).
    private func endOfTurn(_ idle: Report, after running: Report, record: ClaudeRegistryRecord,
                           transcript: TranscriptInfo, session: FollowedSession, now: Date) -> (Report, TurnEnd?) {
        // Another process holds the session now (a resume raced the one that
        // was running): whatever became of that turn, it did not end here.
        if running.pid != idle.pid || running.procStart != idle.procStart {
            session.flipSeenAt = nil
            return (idle, .abandoned)
        }
        if let end = transcript.lastTurnEnd, Self.ends(end, turnStartedAt: running.stateSince) {
            session.flipSeenAt = nil
            return (idle, end.kind)
        }
        var held = running
        held.rawStatus = idle.rawStatus
        if record.isShowingDialog { return (held, nil) }
        // No transcript read yet: there is nothing to wait for.
        guard session.cache.readStamp != nil else {
            session.flipSeenAt = nil
            return (idle, nil)
        }
        let seen = session.flipSeenAt ?? now
        session.flipSeenAt = seen
        if Self.elapsed(from: seen, to: now) < Self.transcriptLagAllowance { return (held, nil) }
        session.flipSeenAt = nil
        return (idle, .completed)
    }

    /// Whether `end` ended the turn that started at `start` rather than an
    /// earlier one. Without both times there is no telling: it counts.
    private static func ends(_ end: TranscriptTurnEnd, turnStartedAt start: Date?) -> Bool {
        guard let at = end.at, let start else { return true }
        return at >= start
    }

    /// customTitle > aiTitle > registry name > last prompt > "Claude <id prefix>".
    static func title(record: ClaudeRegistryRecord, transcript: TranscriptInfo) -> String {
        for candidate in [transcript.customTitle, transcript.aiTitle, record.name] {
            if let title = Formatting.oneLine(candidate, max: 120) { return title }
        }
        if let prompt = Formatting.oneLine(transcript.lastPrompt, max: 80) { return prompt }
        return "Claude " + record.sessionId.prefix(8)
    }

    private func followedSession(for record: ClaudeRegistryRecord, configDir: URL) -> FollowedSession {
        let key = TranscriptKey(configDir: configDir.path, sessionId: record.sessionId)
        if let existing = followed[key] { return existing }
        let session = FollowedSession(cache: ClaudeTranscriptCache(
            sessionId: record.sessionId, configDir: configDir, cwd: record.cwd))
        followed[key] = session
        return session
    }

    /// The session's transcript, re-read when its stamp changed and either
    /// `urgent`, the status flipped (the turn just ended, so the last message
    /// matters now) or 5 s passed since the last read.
    private func transcriptInfo(of session: FollowedSession, record: ClaudeRegistryRecord, now: Date,
                                urgent: Bool) -> TranscriptInfo {
        let cache = session.cache
        guard let stamp = cache.currentStamp(now: now), stamp != cache.readStamp else { return cache.info }
        let statusChanged = session.refreshedAt != nil && session.refreshedStatus != record.status
        let interval = record.status == "busy" ? Self.busyTranscriptRefreshInterval : Self.transcriptRefreshInterval
        let due = session.refreshedAt.map { Self.elapsed(from: $0, to: now) >= interval } ?? true
        guard urgent || statusChanged || due else { return cache.info }
        do {
            try cache.refresh()
        } catch where !ClaudeFileIO.isNotFound(error) {
            let path = cache.url?.path ?? record.sessionId
            report("transcript \(path)", "Claude: cannot read transcript \(path): \(ClaudeFileIO.describe(error))")
        } catch {
            // Gone since the stat: the next poll locates it again.
        }
        session.refreshedAt = now
        session.refreshedStatus = record.status
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
        if followed.keys.contains(where: { winners[$0.sessionId]?.configDir.path != $0.configDir }) {
            followed = followed.filter { winners[$0.key.sessionId]?.configDir.path == $0.key.configDir }
        }
    }

    /// Logs a problem the first time it is seen, never once per poll.
    private func report(_ problem: String, _ message: @autoclosure () -> String) {
        guard reported.insert(problem).inserted else { return }
        log(message())
    }
}
