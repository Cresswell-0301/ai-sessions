import Darwin
import XCTest
@testable import AISessionsCore

final class TrackerTests: XCTestCase {
    // MARK: - Fixtures

    private final class FakeSource: SessionSource {
        let agent: Agent
        var observations: [Observation]
        private(set) var polls = 0
        private(set) var lastPollTime: Date?

        init(_ agent: Agent, _ observations: [Observation] = []) {
            self.agent = agent
            self.observations = observations
        }

        func poll(now: Date) -> [Observation] {
            polls += 1
            lastPollTime = now
            return observations
        }
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private static let scratchHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-sessions-tests-home", isDirectory: true)
    private static var savedHome: String?

    /// Log.shared writes under AppPaths.home: keep it off the real ~/.ai-sessions.
    override class func setUp() {
        super.setUp()
        savedHome = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        setenv("AI_SESSIONS_HOME", scratchHome.path, 1)
    }

    override class func tearDown() {
        Log.shared.flush()
        if let savedHome { setenv("AI_SESSIONS_HOME", savedHome, 1) } else { unsetenv("AI_SESSIONS_HOME") }
        super.tearDown()
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_800_000)
    private var root: URL!
    private var clock: Clock!
    private var stateURL: URL { root.appendingPathComponent("state/state.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = Clock(t0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTracker(_ sources: [SessionSource], store: StateStore? = nil,
                             config: Config = Config()) -> Tracker {
        let clock = self.clock!
        return Tracker(sources: sources, store: store ?? StateStore(url: stateURL), config: config,
                       now: { clock.now })
    }

    /// A tracker on a fresh state file that has already adopted the source's
    /// sessions (a first run, so silently).
    private func adopted(_ source: FakeSource, config: Config = Config(),
                         file: StaticString = #filePath, line: UInt = #line) -> Tracker {
        let tracker = makeTracker([source], config: config)
        XCTAssertEqual(tracker.tick(), [], "a first run adopts silently", file: file, line: line)
        return tracker
    }

    /// One app run that ticks once and quits; the next tracker is a restart.
    private func runAppOnce(_ source: FakeSource) {
        makeTracker([source]).tick()
        clock.advance(1)
    }

    private func key(_ id: String, _ agent: Agent = .claude) -> SessionKey {
        SessionKey(agent: agent, id: id)
    }

    private func obs(_ id: String, _ state: ActivityState, since: Date?, agent: Agent = .claude,
                     title: String? = nil, cwd: String? = "/Users/me/project",
                     message: String? = nil, interactive: Bool = true, turnEnd: TurnEnd? = nil,
                     pid: Int32? = nil, procStart: String? = nil) -> Observation {
        Observation(key: key(id, agent), state: state, stateSince: since, title: title, cwd: cwd, pid: pid,
                    lastMessage: message, interactive: interactive, procStart: procStart, turnEnd: turnEnd)
    }

    /// "finished claude:a", "ended codex:x", … for readable assertions.
    private func names(_ events: [TrackerEvent]) -> [String] {
        events.map { event -> String in
            switch event {
            case .finished(let session): return "finished \(session.key)"
            case .needsInput(let session): return "needsInput \(session.key)"
            case .resumed(let key): return "resumed \(key)"
            case .ended(let key): return "ended \(key)"
            }
        }
    }

    // MARK: - Rules table

    func testRunningToIdleFinishesWithTheTurnDurationAndALongTurnIsUnread() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = adopted(source)
        clock.advance(40)
        source.observations = [obs("a", .idle, since: t0 + 30)]
        let events = tracker.tick()
        XCTAssertEqual(names(events), ["finished claude:a"])
        guard case .finished(let session)? = events.first else { return }
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.stateSince, t0 + 30)
        XCTAssertEqual(session.turnStartedAt, t0)
        XCTAssertEqual(session.lastTurnDuration, 30)
        XCTAssertTrue(session.unread)
        XCTAssertEqual(tracker.session(for: key("a")), session, "the event carries the stored session")
    }

    func testAShortTurnFinishesReadAndAnUnknownDurationCountsAsShort() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0), obs("b", .running, since: t0)])
        let tracker = adopted(source)
        clock.advance(10)
        source.observations = [obs("a", .idle, since: t0 + 3), obs("b", .idle, since: nil)]
        XCTAssertEqual(names(tracker.tick()), ["finished claude:a", "finished claude:b"])
        XCTAssertEqual(tracker.session(for: key("a"))?.lastTurnDuration, 3)
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false)
        XCTAssertNil(tracker.session(for: key("b"))?.lastTurnDuration)
        XCTAssertEqual(tracker.session(for: key("b"))?.unread, false)
    }

    func testAFinishedTurnExactlyAtTheThresholdIsUnread() {
        var config = Config()
        config.minTurnSecondsToNotify = 10
        let source = FakeSource(.claude, [obs("equal", .running, since: t0), obs("under", .running, since: t0)])
        let tracker = adopted(source, config: config)
        clock.advance(20)
        source.observations = [obs("equal", .idle, since: t0 + 10), obs("under", .idle, since: t0 + 9.999)]
        XCTAssertEqual(names(tracker.tick()), ["finished claude:equal", "finished claude:under"])
        XCTAssertEqual(tracker.session(for: key("equal"))?.lastTurnDuration, 10)
        XCTAssertEqual(tracker.session(for: key("equal"))?.unread, true, "exactly the threshold is long enough")
        XCTAssertEqual(tracker.session(for: key("under"))?.unread, false)
    }

    func testTheThresholdIsReadFromTheCurrentConfig() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = adopted(source)
        tracker.config.minTurnSecondsToNotify = 60
        clock.advance(50)
        source.observations = [obs("a", .idle, since: t0 + 45)]
        XCTAssertEqual(names(tracker.tick()), ["finished claude:a"])
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false)
    }

    func testAnInterruptedOrAbandonedTurnEndsSilently() {
        let source = FakeSource(.claude, [obs("esc", .running, since: t0), obs("dead", .running, since: t0, agent: .codex),
                                          obs("done", .running, since: t0)])
        let tracker = adopted(source)
        clock.advance(120)
        source.observations = [obs("esc", .idle, since: t0 + 100, turnEnd: .interrupted),
                               obs("dead", .idle, since: t0 + 90, agent: .codex, turnEnd: .abandoned),
                               obs("done", .idle, since: t0 + 110, turnEnd: .completed)]
        XCTAssertEqual(names(tracker.tick()), ["finished claude:done"], "only a completed turn is news")
        for (id, agent, end, duration) in [("esc", Agent.claude, TurnEnd.interrupted, 100.0), ("dead", .codex, .abandoned, 90)] {
            let session = tracker.session(for: key(id, agent))
            XCTAssertEqual(session?.state, .idle, id)
            XCTAssertEqual(session?.unread, false, "\(id): there is no answer to look at")
            XCTAssertEqual(session?.lastTurnEnd, end, id)
            XCTAssertEqual(session?.lastTurnDuration, duration, "\(id): it did run that long")
        }
        XCTAssertEqual(tracker.session(for: key("done"))?.lastTurnEnd, .completed)
        XCTAssertEqual(tracker.session(for: key("done"))?.unread, true)
    }

    func testAnyStateToWaitingNeedsInputAndIsUnread() {
        let source = FakeSource(.claude, [obs("idle", .idle, since: t0), obs("busy", .running, since: t0)])
        let tracker = adopted(source)
        clock.advance(5)
        source.observations = [obs("idle", .waiting, since: t0 + 4), obs("busy", .waiting, since: t0 + 4)]
        let events = tracker.tick()
        XCTAssertEqual(names(events), ["needsInput claude:idle", "needsInput claude:busy"])
        for case .needsInput(let session) in events {
            XCTAssertEqual(session.state, .waiting)
            XCTAssertTrue(session.unread)
        }
        XCTAssertEqual(tracker.session(for: key("busy"))?.turnStartedAt, t0, "waiting is part of the turn")
    }

    func testANewerWaitingPeriodAsksAgain() {
        let source = FakeSource(.claude, [obs("a", .waiting, since: t0)])
        let tracker = adopted(source)
        clock.advance(2)
        XCTAssertEqual(tracker.tick(), [], "the same waiting period is not news")
        tracker.markRead(key("a"))
        clock.advance(2)
        // Approved, ran briefly and asked again, all between two polls.
        source.observations = [obs("a", .waiting, since: t0 + 3)]
        XCTAssertEqual(names(tracker.tick()), ["needsInput claude:a"])
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, true)
    }

    func testAnyStateToRunningResumesAndClearsUnread() {
        let source = FakeSource(.claude, [obs("done", .running, since: t0), obs("asking", .running, since: t0)])
        let tracker = adopted(source)
        clock.advance(60)
        source.observations = [obs("done", .idle, since: t0 + 50), obs("asking", .waiting, since: t0 + 50)]
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("done"))?.unread, true)
        XCTAssertEqual(tracker.session(for: key("asking"))?.unread, true)
        clock.advance(10)
        source.observations = [obs("done", .running, since: t0 + 65), obs("asking", .running, since: t0 + 66)]
        XCTAssertEqual(names(tracker.tick()), ["resumed claude:done", "resumed claude:asking"])
        XCTAssertEqual(tracker.session(for: key("done"))?.unread, false)
        XCTAssertEqual(tracker.session(for: key("asking"))?.unread, false)
        XCTAssertEqual(tracker.session(for: key("done"))?.turnStartedAt, t0 + 65)
        XCTAssertEqual(tracker.session(for: key("asking"))?.turnStartedAt, t0 + 66)
    }

    func testATurnStartFallsBackToNowWhenTheSourceHasNoTime() {
        let source = FakeSource(.claude, [obs("a", .idle, since: t0)])
        let tracker = adopted(source)
        clock.advance(5)
        source.observations = [obs("a", .running, since: nil)]
        XCTAssertEqual(names(tracker.tick()), ["resumed claude:a"])
        XCTAssertEqual(tracker.session(for: key("a"))?.turnStartedAt, t0 + 5)
        clock.advance(20)
        source.observations = [obs("a", .idle, since: t0 + 24)]
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("a"))?.lastTurnDuration, 19)
    }

    func testWaitingToIdleIsSilentAndClearsUnread() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = adopted(source)
        clock.advance(5)
        source.observations = [obs("a", .waiting, since: t0 + 4)]
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, true)
        clock.advance(5)
        source.observations = [obs("a", .idle, since: t0 + 9)]
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key("a"))?.state, .idle)
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false)
    }

    func testIdleToIdleWithANewerStateSinceIsSilentAndKeepsUnread() {
        let source = FakeSource(.claude, [obs("unread", .running, since: t0), obs("read", .idle, since: t0)])
        let tracker = adopted(source)
        clock.advance(60)
        source.observations = [obs("unread", .idle, since: t0 + 50), obs("read", .idle, since: t0)]
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("unread"))?.unread, true)
        clock.advance(5)
        source.observations = [obs("unread", .idle, since: t0 + 63), obs("read", .idle, since: t0 + 63)]
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key("unread"))?.unread, true)
        XCTAssertEqual(tracker.session(for: key("read"))?.unread, false)
        XCTAssertEqual(tracker.session(for: key("unread"))?.stateSince, t0 + 63)
        XCTAssertEqual(tracker.session(for: key("unread"))?.lastTurnDuration, 50, "an unseen turn has no duration")
    }

    func testRunningWithANewerStateSinceStartsANewTurnSilently() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = adopted(source)
        clock.advance(300)
        // The turn ended and a queued prompt started, both between two polls.
        source.observations = [obs("a", .running, since: t0 + 299)]
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key("a"))?.turnStartedAt, t0 + 299)
        clock.advance(5)
        source.observations = [obs("a", .idle, since: t0 + 303)]
        XCTAssertEqual(names(tracker.tick()), ["finished claude:a"])
        XCTAssertEqual(tracker.session(for: key("a"))?.lastTurnDuration, 4)
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false, "only the last running period counts")
    }

    func testAnUnchangedSessionEmitsNothing() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0), obs("b", .waiting, since: t0),
                                          obs("c", .idle, since: t0)])
        let tracker = adopted(source)
        let before = tracker.allSessions
        for _ in 0..<5 {
            clock.advance(1)
            XCTAssertEqual(tracker.tick(), [])
        }
        XCTAssertEqual(tracker.allSessions, before)
    }

    func testAStateSinceThatMovesBackDoesNotFakeANewPeriod() {
        // A source wavering between two readings of the same waiting period.
        let source = FakeSource(.claude, [obs("a", .waiting, since: t0 + 5)])
        let tracker = adopted(source)
        clock.advance(10)
        source.observations = [obs("a", .waiting, since: t0 + 2)]
        XCTAssertEqual(tracker.tick(), [])
        clock.advance(1)
        source.observations = [obs("a", .waiting, since: t0 + 5)]
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key("a"))?.stateSince, t0 + 5)
    }

    func testAMissingSessionEndsAndIsRemoved() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0), obs("b", .idle, since: t0)])
        let tracker = adopted(source)
        clock.advance(1)
        source.observations = [obs("b", .idle, since: t0)]
        XCTAssertEqual(tracker.tick(), [.ended(key("a"))])
        XCTAssertNil(tracker.session(for: key("a")))
        XCTAssertEqual(tracker.allSessions.map(\.key), [key("b")])
        XCTAssertEqual(tracker.sessions.map(\.key), [key("b")])
        clock.advance(1)
        XCTAssertEqual(tracker.tick(), [], "a session ends once")
    }

    // MARK: - Sources

    func testASourceComingBackEmptyEndsOnlyItsOwnSessions() {
        let claude = FakeSource(.claude, [obs("a", .running, since: t0)])
        let codex = FakeSource(.codex, [obs("x", .running, since: t0, agent: .codex)])
        let tracker = makeTracker([claude, codex])
        XCTAssertEqual(tracker.tick(), [])
        clock.advance(30)
        codex.observations = [] // one failed poll
        claude.observations = [obs("a", .idle, since: t0 + 29)]
        XCTAssertEqual(names(tracker.tick()), ["finished claude:a", "ended codex:x"])
        XCTAssertEqual(tracker.session(for: key("a"))?.state, .idle)
        clock.advance(1)
        codex.observations = [obs("x", .running, since: t0, agent: .codex)]
        XCTAssertEqual(tracker.tick(), [], "its comeback is adopted silently")
        XCTAssertEqual(tracker.session(for: key("x", .codex))?.turnStartedAt, t0)
    }

    func testAnEarlierSourceWinsASharedKeyAndTheSessionLivesWhileAnySourceReportsIt() {
        let first = FakeSource(.claude, [obs("a", .running, since: t0, title: "First")])
        let second = FakeSource(.claude, [obs("a", .idle, since: t0 + 1, title: "Second")])
        let tracker = makeTracker([first, second])
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("a"))?.title, "First")
        XCTAssertEqual(tracker.session(for: key("a"))?.state, .running)
        clock.advance(30)
        first.observations = []
        XCTAssertEqual(names(tracker.tick()), ["finished claude:a"], "taken over by the second source, not ended")
        XCTAssertEqual(tracker.session(for: key("a"))?.title, "Second")
    }

    func testEverySourceIsPolledOncePerTickWithTheTrackerClock() {
        let claude = FakeSource(.claude)
        let codex = FakeSource(.codex)
        let tracker = makeTracker([claude, codex])
        tracker.tick()
        XCTAssertEqual(claude.polls, 1)
        XCTAssertEqual(codex.polls, 1)
        XCTAssertEqual(claude.lastPollTime, t0)
        _ = tracker.sessions
        _ = tracker.allSessions
        XCTAssertEqual(claude.polls, 1, "reading does not poll")
    }

    // MARK: - First run, restart and catch-up

    func testAFirstRunAnnouncesNothingOnItsFirstTickOnly() {
        let store = StateStore(url: stateURL)
        XCTAssertTrue(store.isFirstRun)
        let source = FakeSource(.claude, [obs("w", .waiting, since: t0), obs("r", .running, since: t0),
                                          obs("i", .idle, since: t0)])
        let tracker = makeTracker([source], store: store)
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertFalse(store.isFirstRun)
        XCTAssertFalse(tracker.allSessions.contains(where: \.unread))
        XCTAssertFalse(StateStore(url: stateURL).isFirstRun, "the first tick persisted the baseline")
        clock.advance(30)
        source.observations = [obs("w", .waiting, since: t0), obs("r", .idle, since: t0 + 20),
                               obs("i", .idle, since: t0)]
        XCTAssertEqual(names(tracker.tick()), ["finished claude:r"])
    }

    func testAFirstRunStaysSilentEvenWhenARecordWouldCatchUp() throws {
        // A file that holds a running record but was never initialized.
        let seeded = StateStore(url: stateURL)
        seeded.update(.init(state: .running, stateSince: t0, turnStartedAt: t0, lastSeen: t0), for: key("a"))
        try seeded.save(now: t0)
        let store = StateStore(url: stateURL)
        XCTAssertTrue(store.isFirstRun)
        XCTAssertNotNil(store.record(for: key("a")))
        clock.advance(120)
        let source = FakeSource(.claude, [obs("a", .idle, since: t0 + 60)])
        XCTAssertEqual(makeTracker([source], store: store).tick(), [])
    }

    func testCatchUpAfterARestartFinishesWithThePersistedTurnStart() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        runAppOnce(source)
        // While the app is not running, the turn finishes.
        source.observations = [obs("a", .idle, since: t0 + 600)]
        clock.advance(3600)
        let store = StateStore(url: stateURL)
        XCTAssertFalse(store.isFirstRun)
        let tracker = makeTracker([source], store: store)
        let events = tracker.tick()
        XCTAssertEqual(names(events), ["finished claude:a"])
        guard case .finished(let session)? = events.first else { return }
        XCTAssertEqual(session.turnStartedAt, t0)
        XCTAssertEqual(session.lastTurnDuration, 600)
        XCTAssertTrue(session.unread)
        clock.advance(1)
        XCTAssertEqual(tracker.tick(), [], "announced once")
        XCTAssertEqual(makeTracker([source]).tick(), [], "and not again after another restart")
    }

    func testCatchUpOfAShortTurnIsReadAndCatchUpNeedsANewerStateSince() {
        let source = FakeSource(.claude, [obs("short", .running, since: t0), obs("same", .running, since: t0),
                                          obs("unknown", .running, since: t0)])
        runAppOnce(source)
        source.observations = [obs("short", .idle, since: t0 + 4), obs("same", .idle, since: t0),
                               obs("unknown", .idle, since: nil)]
        clock.advance(60)
        let tracker = makeTracker([source])
        XCTAssertEqual(names(tracker.tick()), ["finished claude:short"])
        XCTAssertEqual(tracker.session(for: key("short"))?.lastTurnDuration, 4)
        XCTAssertEqual(tracker.session(for: key("short"))?.unread, false)
        XCTAssertEqual(tracker.session(for: key("same"))?.unread, false)
        XCTAssertEqual(tracker.session(for: key("unknown"))?.unread, false)
    }

    /// Pinned silence for `toWaiting` until review finding 6: a question asked
    /// while the app was not running blocks the agent and is news.
    func testAQuestionAskedWhileTheAppWasNotRunningIsAnnouncedAndOtherChangesAdoptedSilently() {
        let source = FakeSource(.claude, [obs("toWaiting", .running, since: t0), obs("toRunning", .idle, since: t0),
                                          obs("stillRunning", .running, since: t0)])
        runAppOnce(source)
        source.observations = [obs("toWaiting", .waiting, since: t0 + 30), obs("toRunning", .running, since: t0 + 30),
                               obs("stillRunning", .running, since: t0)]
        clock.advance(60)
        let tracker = makeTracker([source])
        XCTAssertEqual(names(tracker.tick()), ["needsInput claude:toWaiting"])
        XCTAssertEqual(tracker.session(for: key("toWaiting"))?.unread, true)
        XCTAssertEqual(tracker.session(for: key("toWaiting"))?.turnStartedAt, t0, "waiting is part of the turn")
        XCTAssertEqual(tracker.session(for: key("toRunning"))?.turnStartedAt, t0 + 30)
        XCTAssertEqual(tracker.session(for: key("stillRunning"))?.turnStartedAt, t0, "the remembered turn start")
    }

    func testTheProcessAndTheTurnEndArePersistedAndRestored() {
        let start = "Thu Oct  1 02:59:07 2026"
        let source = FakeSource(.claude, [obs("a", .running, since: t0, pid: 42, procStart: start)])
        let tracker = adopted(source)
        clock.advance(60)
        source.observations = [obs("a", .idle, since: t0 + 50, turnEnd: .interrupted, pid: 42, procStart: start)]
        XCTAssertEqual(tracker.tick(), [])
        let record = StateStore(url: stateURL).record(for: key("a"))
        XCTAssertEqual(record?.pid, 42)
        XCTAssertEqual(record?.procStart, start)
        XCTAssertEqual(record?.lastTurnEnd, .interrupted)
        let restarted = makeTracker([source])
        XCTAssertEqual(restarted.tick(), [])
        XCTAssertEqual(restarted.session(for: key("a"))?.lastTurnEnd, .interrupted, "restored with its duration")
        XCTAssertEqual(restarted.session(for: key("a"))?.lastTurnDuration, 50)
    }

    func testCatchUpNeedsTheSameProcessNotJustTheSamePid() {
        let start = "Thu Oct  1 02:59:07 2026"
        let source = FakeSource(.claude, [obs("reused", .running, since: t0, pid: 42, procStart: start),
                                          obs("same", .running, since: t0, pid: 43, procStart: start)])
        runAppOnce(source)
        source.observations = [obs("reused", .idle, since: t0 + 600, pid: 42, procStart: "Thu Oct  1 04:00:00 2026"),
                               obs("same", .idle, since: t0 + 600, pid: 43, procStart: start)]
        clock.advance(900)
        let tracker = makeTracker([source])
        XCTAssertEqual(names(tracker.tick()), ["finished claude:same"], "pid 42 now belongs to another process")
        XCTAssertEqual(tracker.session(for: key("reused"))?.unread, false)
    }

    func testCatchUpOfAnInterruptedTurnIsSilent() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0, pid: 42)])
        runAppOnce(source)
        source.observations = [obs("a", .idle, since: t0 + 600, turnEnd: .interrupted, pid: 42)]
        clock.advance(900)
        let tracker = makeTracker([source])
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key("a"))?.lastTurnEnd, .interrupted)
        XCTAssertEqual(tracker.session(for: key("a"))?.lastTurnDuration, 600)
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false)
    }

    func testCatchUpReachesBackAnHourFromTheTurnsEnd() {
        let source = FakeSource(.claude, [obs("edge", .running, since: t0), obs("late", .running, since: t0)])
        runAppOnce(source)
        source.observations = [obs("edge", .idle, since: t0 + 100), obs("late", .idle, since: t0 + 99)]
        clock.now = t0 + 100 + Tracker.catchUpWindow
        let tracker = makeTracker([source])
        XCTAssertEqual(names(tracker.tick()), ["finished claude:edge"], "exactly an hour ago still counts")
        XCTAssertEqual(tracker.session(for: key("late"))?.state, .idle)
        XCTAssertEqual(tracker.session(for: key("late"))?.unread, false)
    }

    func testAQuestionAskedByAutomationWhileTheAppWasNotRunningStaysSilent() {
        let source = FakeSource(.claude, [obs("bot", .running, since: t0, interactive: false)])
        runAppOnce(source)
        source.observations = [obs("bot", .waiting, since: t0 + 30, interactive: false)]
        clock.advance(60)
        let tracker = makeTracker([source])
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key("bot"))?.unread, false)
    }

    func testNoCatchUpForASessionThatEndedWhileTheAppWatched() {
        // A window reload kills the turn; the resumed session comes back idle.
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = makeTracker([source])
        tracker.tick()
        clock.advance(1)
        source.observations = []
        XCTAssertEqual(tracker.tick(), [.ended(key("a"))])
        clock.advance(30)
        source.observations = [obs("a", .idle, since: t0 + 30)]
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false)
    }

    func testNoCatchUpAfterARestartForASessionThatEndedBeforeTheAppQuit() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = makeTracker([source])
        tracker.tick()
        clock.advance(1)
        source.observations = []
        XCTAssertEqual(tracker.tick(), [.ended(key("a"))])
        source.observations = [obs("a", .idle, since: t0 + 30)]
        clock.advance(60)
        XCTAssertEqual(makeTracker([source]).tick(), [])
    }

    func testNoCatchUpForASessionThatWasGoneWhenTheAppCameBack() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        runAppOnce(source)
        source.observations = [] // its process exited while the app was not running
        clock.advance(60)
        let tracker = makeTracker([source])
        XCTAssertEqual(tracker.tick(), [])
        clock.advance(30)
        source.observations = [obs("a", .idle, since: t0 + 90)] // resumed later
        XCTAssertEqual(tracker.tick(), [])
    }

    func testNoCatchUpFromARecordOlderThanTheRetention() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        runAppOnce(source)
        source.observations = [obs("a", .idle, since: t0 + 3600)]
        clock.advance(StateStore.retention + 60)
        let store = StateStore(url: stateURL)
        XCTAssertNotNil(store.record(for: key("a")), "still on disk until pruned")
        let tracker = makeTracker([source], store: store)
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false)
    }

    func testUnreadSurvivesARestart() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0), obs("w", .running, since: t0)])
        let first = makeTracker([source])
        first.tick()
        clock.advance(60)
        source.observations = [obs("a", .idle, since: t0 + 45), obs("w", .waiting, since: t0 + 50)]
        XCTAssertEqual(names(first.tick()), ["finished claude:a", "needsInput claude:w"])
        clock.advance(600)
        let restarted = makeTracker([source], store: StateStore(url: stateURL))
        XCTAssertEqual(restarted.tick(), [], "nothing is announced again")
        XCTAssertEqual(restarted.session(for: key("a"))?.unread, true)
        XCTAssertEqual(restarted.session(for: key("a"))?.lastTurnDuration, 45)
        XCTAssertEqual(restarted.session(for: key("w"))?.unread, true)
    }

    // MARK: - Read state

    func testMarkReadPersistsAtOnce() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0), obs("b", .running, since: t0)])
        let tracker = makeTracker([source])
        tracker.tick()
        clock.advance(60)
        source.observations = [obs("a", .idle, since: t0 + 50), obs("b", .idle, since: t0 + 50)]
        tracker.tick()
        clock.advance(5)
        tracker.markRead(key("a"))
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false)
        XCTAssertEqual(tracker.session(for: key("a"))?.lastChange, clock.now)
        let onDisk = StateStore(url: stateURL)
        XCTAssertEqual(onDisk.record(for: key("a"))?.unread, false, "written without another tick")
        XCTAssertEqual(onDisk.record(for: key("b"))?.unread, true)
        let restarted = makeTracker([source], store: StateStore(url: stateURL))
        restarted.tick()
        XCTAssertEqual(restarted.session(for: key("a"))?.unread, false)
        XCTAssertEqual(restarted.session(for: key("b"))?.unread, true)
    }

    func testMarkReadOfAnEndedSessionKeepsItReadWhenItReturns() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = makeTracker([source])
        tracker.tick()
        clock.advance(60)
        source.observations = [obs("a", .idle, since: t0 + 50)]
        tracker.tick()
        clock.advance(1)
        source.observations = []
        tracker.tick()
        tracker.markRead(key("a")) // say, its notification clicked after the process exited
        XCTAssertEqual(StateStore(url: stateURL).record(for: key("a"))?.unread, false)
        clock.advance(1)
        source.observations = [obs("a", .idle, since: t0 + 50)]
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false)
    }

    func testMarkAllReadClearsEverySessionAndPersists() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0), obs("b", .running, since: t0),
                                          obs("gone", .running, since: t0)])
        let tracker = makeTracker([source])
        tracker.tick()
        clock.advance(60)
        source.observations = [obs("a", .idle, since: t0 + 50), obs("b", .waiting, since: t0 + 50),
                               obs("gone", .idle, since: t0 + 50)]
        tracker.tick()
        clock.advance(1)
        source.observations = Array(source.observations.prefix(2))
        tracker.tick()
        XCTAssertEqual(StateStore(url: stateURL).records.values.filter(\.unread).count, 3)
        tracker.markAllRead()
        XCTAssertFalse(tracker.allSessions.contains(where: \.unread))
        XCTAssertFalse(StateStore(url: stateURL).records.values.contains(where: \.unread))
    }

    // MARK: - Automation sessions

    func testAutomationSessionsAreTrackedButHiddenAndSilent() {
        let source = FakeSource(.claude, [obs("bot", .running, since: t0, interactive: false),
                                          obs("me", .idle, since: t0)])
        let tracker = adopted(source)
        XCTAssertEqual(tracker.sessions.map(\.key), [key("me")])
        XCTAssertEqual(Set(tracker.allSessions.map(\.key)), [key("bot"), key("me")])
        XCTAssertNotNil(tracker.session(for: key("bot")))
        let me = obs("me", .idle, since: t0)
        for (seconds, state, since) in [(5.0, ActivityState.waiting, t0 + 4), (5, .running, t0 + 9), (60, .idle, t0 + 69)] {
            clock.advance(seconds)
            source.observations = [obs("bot", state, since: since, interactive: false), me]
            XCTAssertEqual(tracker.tick(), [], "no event for \(state)")
            XCTAssertEqual(tracker.session(for: key("bot"))?.unread, false)
        }
        XCTAssertEqual(tracker.session(for: key("bot"))?.lastTurnDuration, 60)
        clock.advance(1)
        source.observations = [me]
        XCTAssertEqual(tracker.tick(), [], "no .ended either")
    }

    func testShowAutomationSessionsListsAndAnnouncesThem() {
        let source = FakeSource(.claude, [obs("bot", .running, since: t0, interactive: false)])
        let tracker = adopted(source)
        XCTAssertEqual(tracker.sessions, [])
        tracker.config.showAutomationSessions = true
        XCTAssertEqual(tracker.sessions.map(\.key), [key("bot")], "applies without a tick")
        clock.advance(60)
        source.observations = [obs("bot", .idle, since: t0 + 30, interactive: false)]
        XCTAssertEqual(names(tracker.tick()), ["finished claude:bot"])
        XCTAssertEqual(tracker.session(for: key("bot"))?.unread, true)
        clock.advance(1)
        source.observations = []
        XCTAssertEqual(tracker.tick(), [.ended(key("bot"))])
    }

    // MARK: - Display

    func testDisplayOrderIsWaitingUnreadRunningIdleThenMostRecentChange() {
        clock.now = t0 + 100
        let source = FakeSource(.claude, [
            obs("w1", .waiting, since: t0 + 10), obs("w2", .waiting, since: t0 + 20),
            obs("r1", .running, since: t0 + 30), obs("r2", .running, since: t0 + 40),
            obs("i1", .idle, since: t0 + 50), obs("i2", .idle, since: t0 + 60),
            obs("u1", .running, since: t0), obs("u2", .running, since: t0),
            obs("bot", .waiting, since: t0 + 90, interactive: false),
        ])
        let tracker = adopted(source)
        clock.now = t0 + 200
        source.observations[6] = obs("u1", .idle, since: t0 + 190)
        tracker.tick()
        clock.now = t0 + 300
        source.observations[7] = obs("u2", .idle, since: t0 + 290)
        tracker.tick()
        XCTAssertEqual(tracker.sessions.map(\.key.id), ["w2", "w1", "u2", "u1", "r2", "r1", "i2", "i1"])
        XCTAssertEqual(tracker.allSessions.map(\.key.id), ["bot", "w2", "w1", "u2", "u1", "r2", "r1", "i2", "i1"])
        clock.now = t0 + 400
        tracker.markRead(key("u1"))
        XCTAssertEqual(tracker.sessions.map(\.key.id), ["w2", "w1", "u2", "r2", "r1", "u1", "i2", "i1"],
                       "once read it is idle, and the most recent change in that group")
    }

    func testTitleFallsBackToAgentAndShortIdAndReportedTextSticks() {
        let claudeID = "9eb4895f-b5d9-41d0-8161-864ac0eecf46"
        let codexID = "0199a1b2-7c3d-7e4f"
        let worktree = "/Users/nexflo/coreOS/.claude/worktrees/inventory"
        let source = FakeSource(.claude, [obs(claudeID, .idle, since: t0, cwd: worktree),
                                          obs(codexID, .idle, since: t0, agent: .codex, title: "  ", cwd: nil)])
        let tracker = adopted(source)
        XCTAssertEqual(tracker.session(for: key(claudeID))?.title, "Claude 9eb4895f")
        XCTAssertEqual(tracker.session(for: key(claudeID))?.project, "coreOS/inventory")
        XCTAssertEqual(tracker.session(for: key(codexID, .codex))?.title, "Codex 0199a1b2")
        XCTAssertEqual(tracker.session(for: key(codexID, .codex))?.project, "")

        clock.advance(1)
        source.observations = [obs(claudeID, .idle, since: t0, title: "AI Track", cwd: "/Users/nexflo/coreOS",
                                   message: "Done.")]
        tracker.tick()
        clock.advance(1)
        source.observations = [obs(claudeID, .idle, since: t0, title: nil, cwd: nil, message: " ")]
        tracker.tick()
        var session = tracker.session(for: key(claudeID))
        XCTAssertEqual(session?.title, "AI Track")
        XCTAssertEqual(session?.lastMessage, "Done.")
        XCTAssertEqual(session?.cwd, "/Users/nexflo/coreOS")
        XCTAssertEqual(session?.project, "coreOS")

        clock.advance(1)
        source.observations = [obs(claudeID, .idle, since: t0, title: "Renamed", message: "Next.")]
        tracker.tick()
        session = tracker.session(for: key(claudeID))
        XCTAssertEqual(session?.title, "Renamed")
        XCTAssertEqual(session?.lastMessage, "Next.")
        XCTAssertEqual(session?.project, "project")
    }

    func testHostAndProcessFieldsFollowTheLatestObservation() {
        let id = key("a")
        let source = FakeSource(.claude, [Observation(
            key: id, state: .running, rawStatus: "busy", stateSince: t0, pid: 42,
            entrypoint: "claude-vscode", host: .vscode(extensionHostPid: 7))])
        let tracker = adopted(source)
        var session = tracker.session(for: id)
        XCTAssertEqual(session?.rawStatus, "busy")
        XCTAssertEqual(session?.pid, 42)
        XCTAssertEqual(session?.entrypoint, "claude-vscode")
        XCTAssertEqual(session?.host, .vscode(extensionHostPid: 7))
        clock.advance(1)
        source.observations = [Observation(key: id, state: .running, rawStatus: "busy", stateSince: t0,
                                           pid: 43, host: .terminal(appPid: 9))]
        tracker.tick()
        session = tracker.session(for: id)
        XCTAssertEqual(session?.pid, 43)
        XCTAssertNil(session?.entrypoint)
        XCTAssertEqual(session?.host, .terminal(appPid: 9))
    }

    func testLastChangeMovesOnlyWhenStateOrUnreadChanges() {
        clock.now = t0 + 2
        let source = FakeSource(.claude, [obs("a", .running, since: t0 + 1)])
        let tracker = adopted(source)
        XCTAssertEqual(tracker.session(for: key("a"))?.lastChange, t0 + 1, "adopted: when the state began")
        XCTAssertEqual(tracker.session(for: key("a"))?.firstSeen, t0 + 2)
        clock.advance(10)
        source.observations = [obs("a", .running, since: t0 + 1, title: "Titled", message: "progress")]
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("a"))?.lastChange, t0 + 1)
        clock.advance(10)
        source.observations = [obs("a", .idle, since: t0 + 21)]
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("a"))?.lastChange, t0 + 22)
        clock.advance(10)
        tracker.markRead(key("a"))
        XCTAssertEqual(tracker.session(for: key("a"))?.lastChange, t0 + 32)
        clock.advance(10)
        tracker.markRead(key("a"))
        XCTAssertEqual(tracker.session(for: key("a"))?.lastChange, t0 + 32, "already read: nothing changed")
        XCTAssertEqual(tracker.session(for: key("a"))?.firstSeen, t0 + 2)
    }

    // MARK: - Persistence

    func testRecordsOfEndedSessionsArePrunedAfterADay() {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = makeTracker([source])
        tracker.tick()
        clock.advance(60)
        source.observations = [obs("a", .idle, since: t0 + 50)]
        tracker.tick() // unread; last seen at t0 + 60
        clock.advance(1)
        source.observations = []
        tracker.tick()
        XCTAssertEqual(StateStore(url: stateURL).record(for: key("a"))?.unread, true, "kept after it ended")
        clock.advance(StateStore.retention - 10)
        tracker.tick()
        XCTAssertNotNil(StateStore(url: stateURL).record(for: key("a")), "not a day yet")
        clock.advance(20)
        tracker.tick()
        XCTAssertNil(StateStore(url: stateURL).record(for: key("a")), "pruned and written")
        clock.advance(1)
        source.observations = [obs("a", .idle, since: t0 + 50)]
        tracker.tick()
        XCTAssertEqual(tracker.session(for: key("a"))?.unread, false, "nothing left to restore")
    }

    func testAnUnchangedSessionIsNotRewrittenEveryTick() throws {
        let source = FakeSource(.claude, [obs("a", .running, since: t0)])
        let tracker = adopted(source)
        // Every save renames a fresh file into place, so the file id changes on any write.
        let fileID = { try FileManager.default.attributesOfItem(atPath: self.stateURL.path)[.systemFileNumber] as? Int }
        let firstID = try fileID()
        for _ in 0..<10 {
            clock.advance(1)
            tracker.tick()
        }
        XCTAssertEqual(StateStore(url: stateURL).record(for: key("a"))?.lastSeen, t0,
                       "lastSeen alone is not written every tick")
        XCTAssertEqual(try fileID(), firstID, "no write at all")
        clock.advance(StateStore.lastSeenWriteInterval)
        tracker.tick()
        XCTAssertEqual(StateStore(url: stateURL).record(for: key("a"))?.lastSeen, clock.now,
                       "lastSeen is refreshed every few minutes")
    }

    func testACorruptStateFileMeansASilentFirstTick() throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"initialized": true, "sessions": {"claude:a": {"state": "runn"#.utf8).write(to: stateURL)
        let store = StateStore(url: stateURL)
        XCTAssertTrue(store.isFirstRun, "a corrupt file reads as no file")
        let source = FakeSource(.claude, [obs("a", .idle, since: t0 + 30), obs("b", .waiting, since: t0)])
        let tracker = makeTracker([source], store: store)
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertFalse(StateStore(url: stateURL).isFirstRun, "a clean file replaced it")
        clock.advance(1)
        source.observations = [obs("a", .waiting, since: t0 + 31), obs("b", .waiting, since: t0)]
        XCTAssertEqual(names(tracker.tick()), ["needsInput claude:a"])
    }
}
