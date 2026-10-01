import Darwin
import XCTest
@testable import AISessionsCore

/// Claude keeps a session's record "busy" while background work it started
/// (agents, workflows, shells) still runs, even after it has answered. The
/// user's "done" is the answer, so it is read from the transcript: busy, but
/// resting on this turn's end_turn. Seen live on 2026-10-01: a session that
/// answered a dozen times behind a background workflow never left "busy".
final class BusyAnswerTests: XCTestCase {
    private static let scratchHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-sessions-tests-home", isDirectory: true)
    private static var savedHome: String?

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

    private let t0 = Date(timeIntervalSince1970: 1_790_800_000)
    private let sessionId = "5a5a5a5a-2222-4222-8333-944455556666"
    private let pid: Int32 = 4343
    private var root: URL!
    private var clock: Clock!
    private var key: SessionKey { SessionKey(agent: .claude, id: sessionId) }
    private var claudeDir: URL { root.appendingPathComponent("claude") }
    private var transcriptURL: URL { claudeDir.appendingPathComponent("projects/-work-demo-app/\(sessionId).jsonl") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("busy-answer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = Clock(t0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func names(_ events: [TrackerEvent]) -> [String] {
        events.map { event -> String in
            switch event {
            case .finished(let session): return "finished after \(Int(session.lastTurnDuration ?? -1))s"
            case .needsInput: return "needsInput"
            case .resumed: return "resumed"
            case .ended: return "ended"
            }
        }
    }

    private func writeRecord(_ status: String, at time: Date) throws {
        let millis = time.timeIntervalSince1970 * 1000
        let record: [String: Any] = [
            "pid": pid, "sessionId": sessionId, "cwd": "/work/demo-app",
            "startedAt": (t0.timeIntervalSince1970 - 3600) * 1000, "procStart": "Thu Oct  1 02:59:07 2026",
            "kind": "interactive", "entrypoint": "claude-vscode",
            "status": status, "updatedAt": millis, "statusUpdatedAt": millis,
        ]
        let sessions = claudeDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record).write(to: sessions.appendingPathComponent("\(pid).json"))
    }

    private func append(_ entries: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = ClaudeFixtures.lines(entries)
        guard let handle = try? FileHandle(forWritingTo: transcriptURL) else { return try data.write(to: transcriptURL) }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func user(_ text: String, at time: Date, sidechain: Bool = false) -> [String: Any] {
        ["type": "user", "isSidechain": sidechain, "sessionId": sessionId, "timestamp": Self.iso(time),
         "message": ["role": "user", "content": text] as [String: Any]]
    }

    private func assistant(_ text: String, stop: String, at time: Date, sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "isSidechain": sidechain, "sessionId": sessionId, "timestamp": Self.iso(time),
         "message": ["role": "assistant", "content": [["type": "text", "text": text]], "stop_reason": stop] as [String: Any]]
    }

    private func source() -> ClaudeSource {
        let pid = self.pid
        let probe = ClaudeProcessProbe(isAlive: { $0 == pid }, startMatches: { _ in true }, host: { _ in .unknown })
        return ClaudeSource(configDirs: [claudeDir], log: { _ in }, probe: probe)
    }

    /// A turn running since t0 (busy since t0), adopted on the first run.
    private func runningTracker() throws -> Tracker {
        try append([
            ["type": "ai-title", "aiTitle": "Session tracker", "sessionId": sessionId],
            assistant("Ready.", stop: "end_turn", at: t0 - 600),
            user("build the tracker", at: t0),
            assistant("Launching a background workflow.", stop: "tool_use", at: t0 + 5),
        ])
        try writeRecord("busy", at: t0)
        clock.now = t0 + 1
        let clock = self.clock!
        let tracker = Tracker(sources: [source()], store: StateStore(url: root.appendingPathComponent("state.json")),
                              config: Config(), now: { clock.now })
        XCTAssertEqual(tracker.tick(), [], "first run: adopted silently")
        XCTAssertEqual(tracker.session(for: key)?.state, .running)
        return tracker
    }

    func testAnAnswerWhileBackgroundWorkKeepsTheSessionBusyIsAnnouncedAsDone() throws {
        let tracker = try runningTracker()
        // Claude answers; its workflow still runs, so the record stays busy.
        try append([assistant("The workflow is running; I'll report back.", stop: "end_turn", at: t0 + 120)])
        clock.now = t0 + 121
        XCTAssertEqual(names(tracker.tick()), ["finished after 120s"])
        let session = tracker.session(for: key)
        XCTAssertEqual(session?.state, .idle)
        XCTAssertEqual(session?.rawStatus, ClaudeSource.answeredWhileBusy)
        XCTAssertEqual(session?.unread, true)
        XCTAssertEqual(session?.lastMessage, "The workflow is running; I'll report back.")

        clock.now = t0 + 140
        XCTAssertEqual(names(tracker.tick()), [], "announced once, not every poll")
    }

    func testTheNextTurnOfTheSameBusyStretchIsTimedFromItsOwnStart() throws {
        let tracker = try runningTracker()
        try append([assistant("Started it.", stop: "end_turn", at: t0 + 120)])
        clock.now = t0 + 121
        XCTAssertEqual(names(tracker.tick()), ["finished after 120s"])

        // The background work finishes and wakes Claude up: a new turn.
        try append([user("<task-notification>workflow completed</task-notification>", at: t0 + 300),
                    assistant("Reading the results.", stop: "tool_use", at: t0 + 305)])
        clock.now = t0 + 306
        XCTAssertEqual(names(tracker.tick()), ["resumed"])
        XCTAssertEqual(tracker.session(for: key)?.state, .running)
        XCTAssertEqual(tracker.session(for: key)?.unread, false)

        try append([assistant("All 19 findings are fixed.", stop: "end_turn", at: t0 + 400)])
        clock.now = t0 + 401
        XCTAssertEqual(names(tracker.tick()), ["finished after 100s"], "300 → 400, not t0 → 400")

        // The background work is over; the record finally leaves busy.
        try writeRecord("idle", at: t0 + 500)
        clock.now = t0 + 501
        XCTAssertEqual(names(tracker.tick()), [], "that answer was already announced")
        XCTAssertEqual(tracker.session(for: key)?.state, .idle)
    }

    func testABusySessionInTheMiddleOfItsTurnIsStillRunning() throws {
        let tracker = try runningTracker()
        try append([user("tool output…", at: t0 + 30), assistant("Checking more.", stop: "tool_use", at: t0 + 31)])
        clock.now = t0 + 40
        XCTAssertEqual(names(tracker.tick()), [])
        XCTAssertEqual(tracker.session(for: key)?.state, .running)
    }

    func testSubAgentChatterAfterTheAnswerDoesNotHideIt() throws {
        let tracker = try runningTracker()
        try append([assistant("Agents are on it.", stop: "end_turn", at: t0 + 60),
                    user("sub-task", at: t0 + 61, sidechain: true),
                    assistant("sub-agent working", stop: "tool_use", at: t0 + 62, sidechain: true)])
        clock.now = t0 + 63
        XCTAssertEqual(names(tracker.tick()), ["finished after 60s"])
    }

    func testAnEscWhileBusyIsSilent() throws {
        let tracker = try runningTracker()
        try append([["type": "user", "isSidechain": false, "sessionId": sessionId, "timestamp": Self.iso(t0 + 50),
                     "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]
                         as [String: Any]]])
        clock.now = t0 + 51
        XCTAssertEqual(names(tracker.tick()), [], "the user stopped it; nothing to announce")
        XCTAssertEqual(tracker.session(for: key)?.state, .idle)
        XCTAssertEqual(tracker.session(for: key)?.unread, false)
    }

    func testThePreviousTurnsAnswerDoesNotCountForANewBusyStretch() throws {
        // Idle session answered at t0-600; the user prompts at t0 and the
        // record flips busy before the prompt reaches the transcript.
        try append([assistant("Ready.", stop: "end_turn", at: t0 - 600)])
        try writeRecord("idle", at: t0 - 600)
        clock.now = t0 - 590
        let clock = self.clock!
        let tracker = Tracker(sources: [source()], store: StateStore(url: root.appendingPathComponent("state.json")),
                              config: Config(), now: { clock.now })
        _ = tracker.tick()
        try writeRecord("busy", at: t0)
        clock.now = t0 + 0.5
        XCTAssertEqual(names(tracker.tick()), ["resumed"])
        XCTAssertEqual(tracker.session(for: key)?.state, .running, "an answer older than the busy stretch is the last turn's")
    }

    func testTheScanReportsRestingAndTheTurnStart() throws {
        try append([user("go", at: t0), assistant("working", stop: "tool_use", at: t0 + 1),
                    assistant("done", stop: "end_turn", at: t0 + 9)])
        var info = try ClaudeTranscript.readTail(of: transcriptURL)
        XCTAssertEqual(info.restingTurnEnd, TranscriptTurnEnd(.completed, at: t0 + 9))
        XCTAssertNil(info.turnStartedAt)

        try append([user("next", at: t0 + 20), assistant("on it", stop: "tool_use", at: t0 + 21)])
        info = try ClaudeTranscript.readTail(of: transcriptURL)
        XCTAssertNil(info.restingTurnEnd)
        XCTAssertEqual(info.turnStartedAt, t0 + 20, "the oldest message after the newest turn end")
        XCTAssertEqual(info.lastTurnEnd, TranscriptTurnEnd(.completed, at: t0 + 9))
    }
}
