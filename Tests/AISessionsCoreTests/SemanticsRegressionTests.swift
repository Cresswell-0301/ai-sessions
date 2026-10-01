import Darwin
import XCTest
@testable import AISessionsCore

/// Regression tests for the review findings on what a user is told
/// (findings 1, 2, 3, 5 and 6). Each one drives the real source where the
/// defect lived, where there is one, then the tracker. A `.finished` event
/// is what posts "done in …" and a `.needsInput` what posts "needs your
/// input", so the assertions are on the events.
final class SemanticsRegressionTests: XCTestCase {
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

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class FakeSource: SessionSource {
        let agent: Agent
        var observations: [Observation]
        init(_ agent: Agent, _ observations: [Observation]) {
            self.agent = agent
            self.observations = observations
        }
        func poll(now: Date) -> [Observation] { observations }
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_800_000)
    private var root: URL!
    private var clock: Clock!
    private var stateURL: URL { root.appendingPathComponent("state/state.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = Clock(t0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tracker(_ sources: [SessionSource]) -> Tracker {
        let clock = self.clock!
        return Tracker(sources: sources, store: StateStore(url: stateURL), config: Config(), now: { clock.now })
    }

    private func names(_ events: [TrackerEvent]) -> [String] {
        events.map { event -> String in
            switch event {
            case .finished(let session): return "finished \(session.key.id)"
            case .needsInput(let session): return "needsInput \(session.key.id)"
            case .resumed(let key): return "resumed \(key.id)"
            case .ended(let key): return "ended \(key.id)"
            }
        }
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // MARK: - Claude fixtures (a fake process table, real files)

    private let claudeSession = "5a5a5a5a-1111-4222-8333-944455556666"
    private let claudePid: Int32 = 4242
    private var claudeKey: SessionKey { SessionKey(agent: .claude, id: claudeSession) }
    private var claudeDir: URL { root.appendingPathComponent("claude") }
    private var transcriptURL: URL {
        claudeDir.appendingPathComponent("projects/-work-demo-app/\(claudeSession).jsonl")
    }

    private func claudeSource() throws -> ClaudeSource {
        let pid = claudePid
        let probe = ClaudeProcessProbe(isAlive: { $0 == pid }, startMatches: { _ in true }, host: { _ in .unknown })
        return ClaudeSource(configDirs: [claudeDir], log: { _ in }, probe: probe)
    }

    /// The registry record as Claude 2.1.284 writes it; `waitingFor` only
    /// with "waiting", as the CLI does.
    private func writeRecord(_ status: String, at time: Date, waitingFor: String? = nil,
                             entrypoint: String = "claude-vscode") throws {
        let millis = time.timeIntervalSince1970 * 1000
        var record: [String: Any] = [
            "pid": claudePid, "sessionId": claudeSession, "cwd": "/work/demo-app",
            "startedAt": (t0.timeIntervalSince1970 - 3600) * 1000, "procStart": "Thu Oct  1 02:59:07 2026",
            "version": "2.1.284", "kind": "interactive", "entrypoint": entrypoint,
            "status": status, "updatedAt": millis, "statusUpdatedAt": millis,
        ]
        record["waitingFor"] = waitingFor
        let sessions = claudeDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record).write(to: sessions.appendingPathComponent("\(claudePid).json"))
    }

    private func appendTranscript(_ entries: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = ClaudeFixtures.lines(entries)
        guard let handle = try? FileHandle(forWritingTo: transcriptURL) else {
            return try data.write(to: transcriptURL)
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func prompt(_ text: String, at time: Date) -> [String: Any] {
        ["type": "user", "sessionId": claudeSession, "timestamp": Self.iso(time),
         "message": ["role": "user", "content": text] as [String: Any]]
    }

    private func assistant(_ text: String, stopReason: String?, at time: Date) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": text]]]
        message["stop_reason"] = stopReason ?? NSNull()
        return ["type": "assistant", "isSidechain": false, "sessionId": claudeSession,
                "timestamp": Self.iso(time), "message": message]
    }

    /// What Claude Code writes when the user presses Esc mid-turn.
    private func interruptMarker(at time: Date, text: String = "[Request interrupted by user]") -> [String: Any] {
        ["type": "user", "sessionId": claudeSession, "timestamp": Self.iso(time),
         "message": ["role": "user", "content": [["type": "text", "text": text]]] as [String: Any]]
    }

    /// A Claude turn running since `t0`, adopted by a tracker on its first run.
    private func runningClaudeTracker(file: StaticString = #filePath, line: UInt = #line) throws -> Tracker {
        try appendTranscript([
            ["type": "ai-title", "aiTitle": "Ledger refactor", "sessionId": claudeSession],
            assistant("All set up.", stopReason: "end_turn", at: t0 - 600),
            prompt("refactor the ledger", at: t0),
            assistant("Let me look at the ledger first.", stopReason: "tool_use", at: t0 + 5),
        ])
        try writeRecord("busy", at: t0)
        clock.now = t0 + 1
        let tracker = tracker([try claudeSource()])
        XCTAssertEqual(tracker.tick(), [], "first run: adopted silently", file: file, line: line)
        XCTAssertEqual(tracker.session(for: claudeKey)?.state, .running, file: file, line: line)
        return tracker
    }

    // MARK: - Finding 1: an interrupted turn is announced as "done"

    func testClaudeEscIsNotAnnouncedAsAFinishedTurn() throws {
        let tracker = try runningClaudeTracker()
        // As observed live: the marker reaches the transcript, then busy → idle.
        try appendTranscript([interruptMarker(at: t0 + 150)])
        try writeRecord("idle", at: t0 + 150.2)
        clock.now = t0 + 151
        XCTAssertEqual(names(tracker.tick()), [], "the user pressed Esc in that tab a moment ago")
        XCTAssertEqual(tracker.session(for: claudeKey)?.state, .idle)
        XCTAssertEqual(tracker.session(for: claudeKey)?.unread, false)
    }

    func testClaudeInterruptMarkerFlushedAfterTheFlipIsStillNotAFinishedTurn() throws {
        let tracker = try runningClaudeTracker()
        // The other order: the registry flips before the transcript has the marker.
        try writeRecord("idle", at: t0 + 150)
        clock.now = t0 + 150.3
        XCTAssertEqual(names(tracker.tick()), [], "a flip without the turn's end on disk is not news yet")
        try appendTranscript([interruptMarker(at: t0 + 150.4, text: "[Request interrupted by user for tool use]")])
        clock.now = t0 + 151.2
        XCTAssertEqual(names(tracker.tick()), [])
        XCTAssertEqual(tracker.session(for: claudeKey)?.state, .idle)
        XCTAssertEqual(tracker.session(for: claudeKey)?.unread, false)
    }

    func testClaudeTurnWhoseEndIsNeverRecordedFinishesTwoSecondsAfterTheFlip() throws {
        let tracker = try runningClaudeTracker()
        // Only the previous turn's end_turn is on disk, from before this turn began.
        try writeRecord("idle", at: t0 + 100)
        clock.now = t0 + 100.5
        XCTAssertEqual(names(tracker.tick()), [], "waiting for the transcript to catch up")
        XCTAssertEqual(tracker.session(for: claudeKey)?.state, .running)
        clock.now = t0 + 101.5
        XCTAssertEqual(names(tracker.tick()), [])
        clock.now = t0 + 102.6
        XCTAssertEqual(names(tracker.tick()), ["finished \(claudeSession)"], "then it counts as finished")
        XCTAssertEqual(tracker.session(for: claudeKey)?.lastTurnDuration, 100, "measured to the flip")
        XCTAssertEqual(tracker.session(for: claudeKey)?.unread, true)
    }

    func testClaudeCompletedTurnIsAnnouncedWithoutDelay() throws {
        let tracker = try runningClaudeTracker()
        try appendTranscript([assistant("Done: the ledger is split in two.", stopReason: "end_turn", at: t0 + 99.8)])
        try writeRecord("idle", at: t0 + 100)
        clock.now = t0 + 100.4
        let events = tracker.tick()
        XCTAssertEqual(names(events), ["finished \(claudeSession)"])
        guard case .finished(let session)? = events.first else { return }
        XCTAssertEqual(session.lastMessage, "Done: the ledger is split in two.")
        XCTAssertEqual(session.lastTurnDuration, 100)
    }

    func testCodexStopIsNotAnnouncedAsAFinishedTurn() throws {
        let now = Date()
        let id = "01a0c2d8-e5d4-7b12-aef3-21e7666556fc"
        let url = try writeCodexRollout(id, CodexFixture.meta(id: id, time: Self.iso(now - 300))
            + CodexFixture.taskStarted(Self.iso(now - 240))
            + CodexFixture.userMessage(Self.iso(now - 240), "migrate the finance tables")
            + CodexFixture.agentMessage(Self.iso(now - 180), "Running the migration now."))
        clock.now = now
        let tracker = tracker([codexSource()])
        XCTAssertEqual(tracker.tick(), [])
        let key = SessionKey(agent: .codex, id: id)
        XCTAssertEqual(tracker.session(for: key)?.state, .running)

        // The user clicks Stop two minutes in; Codex persists turn_aborted.
        try append(CodexFixture.turnAborted(Self.iso(now - 120)), to: url)
        clock.now = now + 1
        XCTAssertEqual(names(tracker.tick()), [], "a turn the user just stopped is not done")
        XCTAssertEqual(tracker.session(for: key)?.state, .idle)
        XCTAssertEqual(tracker.session(for: key)?.unread, false)
    }

    // MARK: - Finding 2: a Codex turn whose app-server died runs forever

    private var codexHome: URL { root.appendingPathComponent("codex", isDirectory: true) }

    private func codexSource() -> CodexSource {
        let source = CodexSource(homes: [codexHome], recentHours: 12)
        source.logger = { _ in }
        return source
    }

    private func writeCodexRollout(_ id: String, _ text: String) throws -> URL {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let directory = codexHome.appendingPathComponent(
            String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-10-01T11-00-00-\(id).jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// A turn that started a minute ago and whose rollout was last written now.
    private func deadCodexTurn(_ id: String, now: Date) throws {
        _ = try writeCodexRollout(id, CodexFixture.meta(id: id, time: Self.iso(now - 70))
            + CodexFixture.taskStarted(Self.iso(now - 60))
            + CodexFixture.userMessage(Self.iso(now - 60), "refactor the ledger")
            + CodexFixture.agentMessage(Self.iso(now - 50), "Looking at the ledger module."))
    }

    func testACodexTurnWhoseAppServerDiedDoesNotRunForever() throws {
        let now = Date()
        let id = "01a0c73f-5340-7702-9375-d02c43d3c18f"
        try deadCodexTurn(id, now: now)
        clock.now = now
        let tracker = tracker([codexSource()])
        tracker.tick()
        let key = SessionKey(agent: .codex, id: id)
        XCTAssertEqual(tracker.session(for: key)?.state, .running)

        // VS Code quit mid-turn: no task_complete or turn_aborted is ever written.
        clock.now = now + 4 * 3600
        XCTAssertEqual(names(tracker.tick()), [], "a turn that never finished is not 'done'")
        XCTAssertNotEqual(tracker.session(for: key)?.state, .running, "4 h without a single rollout write")
        XCTAssertEqual(tracker.session(for: key)?.unread, false)
        clock.now = now + 72 * 3600
        tracker.tick()
        XCTAssertFalse(tracker.allSessions.contains { $0.state == .running }, "3 days later")
    }

    func testARestartDoesNotAdoptADeadCodexTurnAsRunning() throws {
        let now = Date()
        let id = "01a0c894-49df-7102-92b1-6cf77abbf88e"
        try deadCodexTurn(id, now: now)
        clock.now = now
        tracker([codexSource()]).tick()

        // The app restarts 6 h later, well within the 12 h recency window.
        clock.now = now + 6 * 3600
        let restarted = tracker([codexSource()])
        XCTAssertEqual(names(restarted.tick()), [], "neither 'done' nor anything else")
        let key = SessionKey(agent: .codex, id: id)
        XCTAssertNotNil(restarted.session(for: key), "still listed: it was active within the window")
        XCTAssertNotEqual(restarted.session(for: key)?.state, .running)
    }

    func testACodexTurnIsGivenUpMinutesAfterTheLastCodexProcessIsGone() throws {
        let now = Date()
        let id = "01a09ee1-98e3-7441-853e-c982175b4e79"
        try deadCodexTurn(id, now: now)
        clock.now = now
        let source = codexSource()
        source.codexProcessExists = { false } // VS Code quit, taking every app-server with it
        let tracker = tracker([source])
        tracker.tick()
        let key = SessionKey(agent: .codex, id: id)
        XCTAssertEqual(tracker.session(for: key)?.state, .running)
        clock.now = now + 3 * 60
        XCTAssertEqual(names(tracker.tick()), [], "given up, silently")
        XCTAssertEqual(tracker.session(for: key)?.state, .idle)
        XCTAssertEqual(tracker.session(for: key)?.lastTurnEnd, .abandoned)
        XCTAssertEqual(tracker.session(for: key)?.unread, false)
    }

    // MARK: - Finding 3: an open slash-command dialog is "needs your input"

    func testOpeningASlashCommandDialogIsNotNeedsInput() throws {
        try writeRecord("idle", at: t0, entrypoint: "cli")
        clock.now = t0 + 1
        let tracker = tracker([try claudeSource()])
        XCTAssertEqual(tracker.tick(), [])
        // What the TUI writes while /model, /config, /resume … is open.
        try writeRecord("waiting", at: t0 + 60, waitingFor: "dialog open", entrypoint: "cli")
        clock.now = t0 + 61
        XCTAssertEqual(names(tracker.tick()), [], "the user is typing in that very terminal")
        XCTAssertEqual(tracker.session(for: claudeKey)?.state, .idle)
        XCTAssertEqual(tracker.session(for: claudeKey)?.unread, false)
        try writeRecord("idle", at: t0 + 75, entrypoint: "cli")
        clock.now = t0 + 76
        XCTAssertEqual(names(tracker.tick()), [], "closing it is not news either")
    }

    func testADialogOpenedMidTurnNeitherAsksNorFinishes() throws {
        let tracker = try runningClaudeTracker()
        try writeRecord("waiting", at: t0 + 30, waitingFor: "dialog open")
        clock.now = t0 + 31
        XCTAssertEqual(names(tracker.tick()), [])
        XCTAssertEqual(tracker.session(for: claudeKey)?.state, .running, "the turn goes on behind the dialog")
        try writeRecord("busy", at: t0 + 40)
        clock.now = t0 + 41
        XCTAssertEqual(names(tracker.tick()), [])
        XCTAssertEqual(tracker.session(for: claudeKey)?.state, .running)
    }

    func testAPermissionPromptStillNeedsInput() throws {
        let tracker = try runningClaudeTracker()
        try writeRecord("waiting", at: t0 + 30, waitingFor: "permission prompt")
        clock.now = t0 + 31
        XCTAssertEqual(names(tracker.tick()), ["needsInput \(claudeSession)"])
        XCTAssertEqual(tracker.session(for: claudeKey)?.unread, true)
    }

    // MARK: - Finding 5: catch-up announces a turn that was killed

    private let claudeID = "9eb4895f-b5d9-41d0-8161-864ac0eecf46"

    private func claudeObservation(_ state: ActivityState, since: Date, pid: Int32) -> Observation {
        Observation(key: SessionKey(agent: .claude, id: claudeID), state: state,
                    rawStatus: state == .running ? "busy" : "idle", stateSince: since,
                    pid: pid, entrypoint: "claude-vscode")
    }

    func testCatchUpDoesNotAnnounceATurnWhoseProcessWasReplaced() {
        let source = FakeSource(.claude, [claudeObservation(.running, since: t0, pid: 48433)])
        tracker([source]).tick()
        // While the app is not running, VS Code restarts: pid 48433 dies
        // mid-turn and the restored tab resumes the session in pid 51200.
        clock.now = t0 + 3 * 3600
        source.observations = [claudeObservation(.idle, since: t0 + 3 * 3600 - 30, pid: 51200)]
        let restarted = tracker([source])
        XCTAssertEqual(names(restarted.tick()), [], "another process: the turn was killed, it did not finish")
        XCTAssertEqual(restarted.session(for: SessionKey(agent: .claude, id: claudeID))?.unread, false)
    }

    func testCatchUpDoesNotAnnounceATurnThatEndedLongAgo() {
        let source = FakeSource(.claude, [claudeObservation(.running, since: t0, pid: 48433)])
        tracker([source]).tick()
        // The turn finished 10 min in; the app comes back 20 h later.
        clock.now = t0 + 20 * 3600
        source.observations = [claudeObservation(.idle, since: t0 + 600, pid: 48433)]
        let restarted = tracker([source])
        XCTAssertEqual(names(restarted.tick()), [], "news from 20 h ago is not news")
        XCTAssertEqual(restarted.session(for: SessionKey(agent: .claude, id: claudeID))?.unread, false)
    }

    func testCatchUpStillAnnouncesARecentTurnOfTheSameProcess() {
        let source = FakeSource(.claude, [claudeObservation(.running, since: t0, pid: 48433)])
        tracker([source]).tick()
        clock.now = t0 + 900
        source.observations = [claudeObservation(.idle, since: t0 + 600, pid: 48433)]
        let restarted = tracker([source])
        XCTAssertEqual(names(restarted.tick()), ["finished \(claudeID)"])
        XCTAssertEqual(restarted.session(for: SessionKey(agent: .claude, id: claudeID))?.lastTurnDuration, 600)
    }

    // MARK: - Finding 6: a question asked while the app was down is adopted silently

    func testAQuestionAskedWhileTheAppWasDownIsAnnounced() {
        let key = SessionKey(agent: .claude, id: "b")
        let source = FakeSource(.claude, [Observation(key: key, state: .running, stateSince: t0)])
        tracker([source]).tick()
        // The app restarts (crash and KeepAlive, reinstall); meanwhile the agent asks for permission.
        clock.now = t0 + 40
        source.observations = [Observation(key: key, state: .waiting, stateSince: t0 + 30)]
        let restarted = tracker([source])
        XCTAssertEqual(names(restarted.tick()), ["needsInput b"], "a prompt that blocks the agent is news")
        XCTAssertEqual(restarted.session(for: key)?.unread, true)
    }

    func testANewQuestionAfterARestartIsAnnouncedButTheSameOneIsNot() {
        let key = SessionKey(agent: .claude, id: "q")
        let source = FakeSource(.claude, [Observation(key: key, state: .waiting, stateSince: t0)])
        tracker([source]).tick() // a first run: adopted silently
        clock.now = t0 + 20
        XCTAssertEqual(tracker([source]).tick(), [], "the same question is not asked twice")
        clock.now = t0 + 60
        source.observations = [Observation(key: key, state: .waiting, stateSince: t0 + 50)]
        XCTAssertEqual(names(tracker([source]).tick()), ["needsInput q"], "a newer question is")
    }

    func testAQuestionPendingOnTheVeryFirstRunIsStillAdoptedSilently() throws {
        // A state file that holds a running record but was never initialized.
        let seeded = StateStore(url: stateURL)
        let key = SessionKey(agent: .claude, id: "w")
        seeded.update(.init(state: .running, stateSince: t0, turnStartedAt: t0, lastSeen: t0), for: key)
        try seeded.save(now: t0)
        clock.now = t0 + 60
        let source = FakeSource(.claude, [Observation(key: key, state: .waiting, stateSince: t0 + 30)])
        let tracker = tracker([source])
        XCTAssertEqual(tracker.tick(), [])
        XCTAssertEqual(tracker.session(for: key)?.unread, false)
    }
}
