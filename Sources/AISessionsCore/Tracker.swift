import Foundation

/// The tracker engine: merges every source's observations into
/// `TrackedSession`s and turns their state changes into `TrackerEvent`s,
/// following DESIGN.md "Tracker rules".
///
/// Not thread-safe, by design: the app calls `tick()`, the accessors and the
/// mark-read methods on one serial queue and hands the UI immutable
/// `[TrackedSession]` snapshots, so nothing here takes a lock.
public final class Tracker {
    /// Read on every tick. Visibility of automation sessions follows it at
    /// once; the turn threshold applies from the next finished turn.
    public var config: Config

    private let sources: [SessionSource]
    private let store: StateStore
    private let now: () -> Date
    private var entries: [SessionKey: Entry] = [:]
    private var hasTicked = false
    /// `allSessions`, sorted; nil once anything it shows has changed.
    private var orderedCache: [TrackedSession]?

    public init(sources: [SessionSource], store: StateStore, config: Config,
                now: @escaping () -> Date = Date.init) {
        self.sources = sources
        self.store = store
        self.config = config
        self.now = now
    }

    // MARK: - Ticking

    /// Polls every source once, applies the rules table to every session and
    /// persists what changed. Events come in source order, then `.ended` by key.
    @discardableResult
    public func tick() -> [TrackerEvent] {
        let now = self.now()
        // On a first run the opening tick only learns the baseline.
        let silent = !hasTicked && store.isFirstRun
        // Before adoption, so an expired record can neither restore nor catch up.
        store.prune(now: now)

        var events: [TrackerEvent] = []
        var live = Set<SessionKey>()
        for observation in pollSources(now: now) {
            let key = observation.key
            live.insert(key)
            let announce = !silent && (observation.interactive || config.showAutomationSessions)
            let previous = entries[key]
            let entry: Entry
            let kind: EventKind?
            if let previous {
                (entry, kind) = advance(previous, with: observation, now: now, announce: announce)
            } else {
                (entry, kind) = adopt(observation, record: store.record(for: key), now: now, announce: announce)
                if announce, kind != nil {
                    Log.shared.info("\(key): a turn finished while the app was not running")
                }
            }
            entries[key] = entry
            if entry.session != previous?.session { orderedCache = nil }
            store.update(Self.record(of: entry.session, seenAt: now), for: key)
            if announce, let kind { events.append(kind.event(for: entry.session)) }
        }

        // A session ends only when no source reports it any more, so a source
        // that comes back empty for a tick cannot end another source's sessions.
        for key in entries.keys.filter({ !live.contains($0) }).sorted() {
            guard let gone = entries.removeValue(forKey: key) else { continue }
            orderedCache = nil
            store.close(key)
            if !silent && (gone.session.interactive || config.showAutomationSessions) {
                events.append(.ended(key))
            }
        }

        if !hasTicked {
            hasTicked = true
            // Sessions that ended while the app was not running.
            store.closeAll(except: live)
            if silent {
                Log.shared.info("first run: adopted \(live.count) session(s) without announcing")
            }
            store.markInitialized()
        }
        store.saveIfNeeded(now: now)
        return events
    }

    /// One observation per key; an earlier source wins a key it shares.
    private func pollSources(now: Date) -> [Observation] {
        var seen = Set<SessionKey>()
        var merged: [Observation] = []
        for source in sources {
            for observation in source.poll(now: now) where seen.insert(observation.key).inserted {
                merged.append(observation)
            }
        }
        return merged
    }

    /// First sight of a session by this tracker: adopt it silently, restoring
    /// what the store remembers, except for the catch-up rule.
    private func adopt(_ observation: Observation, record: StateStore.Record?, now: Date,
                       announce: Bool) -> (Entry, EventKind?) {
        var entry = Entry(session: TrackedSession(
            key: observation.key, title: "", project: "", state: observation.state,
            firstSeen: now, lastChange: min(observation.stateSince ?? now, now)))
        describe(&entry, with: observation)
        var phase = Phase(state: observation.state, stateSince: observation.stateSince)
        var kind: EventKind?
        if let record {
            (phase, kind) = restore(record, to: observation, now: now, announce: announce)
        } else if observation.state == .running {
            phase.turnStartedAt = observation.stateSince ?? now
        }
        phase.apply(to: &entry.session)
        return (entry, kind)
    }

    /// Adoption against a remembered record. Only a turn that finished while
    /// the app was not running is announced; any other change since then is
    /// taken over silently, so it may clear `unread` but never raises it.
    private func restore(_ record: StateStore.Record, to observation: Observation, now: Date,
                         announce: Bool) -> (Phase, EventKind?) {
        var phase = Phase(record)
        if record.state == .running, observation.state == .idle, !record.ended,
           Self.isNewer(observation.stateSince, than: record.stateSince ?? record.turnStartedAt) {
            let duration = Self.turnDuration(from: record.turnStartedAt, to: observation.stateSince)
            phase.state = .idle
            phase.stateSince = observation.stateSince
            phase.lastTurnDuration = duration
            phase.unread = announce && isLongTurn(duration)
            return (phase, .finished)
        }
        if record.state == observation.state,
           !Self.isNewer(observation.stateSince, than: record.stateSince) {
            phase.stateSince = Self.later(record.stateSince, observation.stateSince)
            if phase.state == .running {
                phase.turnStartedAt = phase.stateSince ?? record.turnStartedAt ?? now
            }
            return (phase, nil)
        }
        phase.state = observation.state
        phase.stateSince = observation.stateSince
        switch observation.state {
        case .running:
            phase.turnStartedAt = observation.stateSince ?? now
            phase.unread = false
        case .waiting:
            // Getting here took a running stretch, i.e. the user acted on the
            // session; the new question itself was never announced.
            phase.unread = false
        case .idle:
            // idle → idle keeps `unread`, as it does live.
            if record.state != .idle { phase.unread = false }
        }
        return (phase, nil)
    }

    /// One tick of the rules table for a session already being tracked.
    private func advance(_ entry: Entry, with observation: Observation, now: Date,
                         announce: Bool) -> (Entry, EventKind?) {
        var next = entry
        describe(&next, with: observation)
        let before = Phase(entry.session)
        var phase = before
        var kind: EventKind?
        let stateChanged = observation.state != before.state
        if stateChanged || Self.isNewer(observation.stateSince, than: before.stateSince) {
            phase.state = observation.state
            phase.stateSince = observation.stateSince
            switch (before.state, observation.state) {
            case (_, .running):
                phase.turnStartedAt = observation.stateSince ?? now
                phase.unread = false
                // Running again with no visible gap (a queued prompt): there is
                // no delivered notification to retract.
                kind = stateChanged ? .resumed : nil
            case (_, .waiting):
                // A newer waiting period is a new question, even when the
                // running stretch in between fell between two polls.
                if announce { phase.unread = true }
                kind = .needsInput
            case (.running, .idle):
                let duration = Self.turnDuration(from: before.turnStartedAt, to: observation.stateSince)
                phase.lastTurnDuration = duration
                phase.unread = announce && isLongTurn(duration)
                kind = .finished
            case (.waiting, .idle):
                phase.unread = false // the user dealt with it
            case (.idle, .idle):
                break // a turn too short to see
            }
            next.session.lastChange = now
        } else {
            phase.stateSince = Self.later(before.stateSince, observation.stateSince)
            if phase.state == .running {
                phase.turnStartedAt = phase.stateSince ?? before.turnStartedAt ?? now
            }
        }
        if phase.unread != before.unread { next.session.lastChange = now }
        phase.apply(to: &next.session)
        return (next, kind)
    }

    /// Copies the descriptive fields. Title, last message and cwd stick when a
    /// later observation omits them, so a source that briefly cannot read a
    /// transcript does not blank the row.
    private func describe(_ entry: inout Entry, with observation: Observation) {
        if let title = Self.nonBlank(observation.title) { entry.reportedTitle = title }
        entry.session.title = entry.reportedTitle ?? Self.fallbackTitle(for: observation.key)
        if let message = Self.nonBlank(observation.lastMessage) { entry.session.lastMessage = message }
        if let cwd = observation.cwd, !cwd.isEmpty, cwd != entry.session.cwd {
            entry.session.cwd = cwd
            entry.session.project = Formatting.project(for: cwd)
        }
        entry.session.rawStatus = observation.rawStatus
        entry.session.pid = observation.pid
        entry.session.entrypoint = observation.entrypoint
        entry.session.host = observation.host
        entry.session.interactive = observation.interactive
    }

    // MARK: - Reading

    /// What the menu lists, in display order: waiting, unread, running, idle,
    /// each group most recent `lastChange` first. Automation sessions appear
    /// only with `showAutomationSessions`.
    public var sessions: [TrackedSession] {
        config.showAutomationSessions ? allSessions : allSessions.filter(\.interactive)
    }

    /// Every tracked session, automation included, in display order.
    public var allSessions: [TrackedSession] {
        if let orderedCache { return orderedCache }
        let ordered = entries.values.map(\.session).sorted(by: Self.displayPrecedes)
        orderedCache = ordered
        return ordered
    }

    public func session(for key: SessionKey) -> TrackedSession? {
        entries[key]?.session
    }

    // MARK: - Read state

    /// The user looked at the session. Persisted at once, also for a session
    /// that already ended, so it does not come back unread.
    public func markRead(_ key: SessionKey) {
        let now = self.now()
        clearUnread(key, now: now)
        store.clearUnread(key)
        store.saveIfNeeded(now: now)
    }

    /// Clears `unread` everywhere, ended sessions included, and persists it.
    public func markAllRead() {
        let now = self.now()
        let unread = entries.compactMap { $0.value.session.unread ? $0.key : nil }
        for key in unread { clearUnread(key, now: now) }
        store.clearAllUnread()
        store.saveIfNeeded(now: now)
    }

    private func clearUnread(_ key: SessionKey, now: Date) {
        guard entries[key]?.session.unread == true else { return }
        entries[key]?.session.unread = false
        entries[key]?.session.lastChange = now
        orderedCache = nil
    }

    // MARK: - Helpers

    private static func displayPrecedes(_ a: TrackedSession, _ b: TrackedSession) -> Bool {
        let (groupA, groupB) = (displayGroup(a), displayGroup(b))
        if groupA != groupB { return groupA < groupB }
        if a.lastChange != b.lastChange { return a.lastChange > b.lastChange }
        return a.key < b.key
    }

    private static func displayGroup(_ session: TrackedSession) -> Int {
        if session.state == .waiting { return 0 }
        if session.unread { return 1 }
        return session.state == .running ? 2 : 3
    }

    private static func record(of session: TrackedSession, seenAt now: Date) -> StateStore.Record {
        StateStore.Record(state: session.state, stateSince: session.stateSince,
                          turnStartedAt: session.turnStartedAt,
                          lastTurnDuration: session.lastTurnDuration,
                          unread: session.unread, ended: false, lastSeen: now)
    }

    private static func fallbackTitle(for key: SessionKey) -> String {
        "\(key.agent.displayName) \(key.id.prefix(8))"
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isNewer(_ candidate: Date?, than reference: Date?) -> Bool {
        guard let candidate, let reference else { return false }
        return candidate > reference
    }

    /// The later of two times; within one state period `stateSince` never
    /// moves back, so a source wavering between two values cannot fake a new period.
    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    /// idle.stateSince − turnStartedAt; nil when either end is unknown or the
    /// two disagree about which came first.
    private static func turnDuration(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    /// A finished turn deserves the user's attention iff it lasted at least the
    /// threshold; an unknown duration counts as short.
    private func isLongTurn(_ duration: TimeInterval?) -> Bool {
        guard let duration else { return false }
        return duration >= config.minTurnSecondsToNotify
    }

    // MARK: - Types

    fileprivate struct Entry {
        var session: TrackedSession
        /// The last title a source reported; `session.title` may be the fallback.
        var reportedTitle: String?
    }

    /// The part of a session the rules table reads and writes.
    fileprivate struct Phase {
        var state: ActivityState
        var stateSince: Date?
        var turnStartedAt: Date?
        var lastTurnDuration: TimeInterval?
        var unread = false

        init(state: ActivityState, stateSince: Date?) {
            self.state = state
            self.stateSince = stateSince
        }

        init(_ session: TrackedSession) {
            state = session.state
            stateSince = session.stateSince
            turnStartedAt = session.turnStartedAt
            lastTurnDuration = session.lastTurnDuration
            unread = session.unread
        }

        init(_ record: StateStore.Record) {
            state = record.state
            stateSince = record.stateSince
            turnStartedAt = record.turnStartedAt
            lastTurnDuration = record.lastTurnDuration
            unread = record.unread
        }

        func apply(to session: inout TrackedSession) {
            session.state = state
            session.stateSince = stateSince
            session.turnStartedAt = turnStartedAt
            session.lastTurnDuration = lastTurnDuration
            session.unread = unread
        }
    }

    fileprivate enum EventKind {
        case finished, needsInput, resumed

        func event(for session: TrackedSession) -> TrackerEvent {
            switch self {
            case .finished: return .finished(session)
            case .needsInput: return .needsInput(session)
            case .resumed: return .resumed(session.key)
            }
        }
    }
}
