import AISessionsCore
import UserNotifications
import XCTest
@testable import AISessions

/// Stands in for UNUserNotificationCenter: keeps what Notification Center
/// would show, so a test can ask which banners are up. Nothing is posted.
final class RecordingCenter: NotificationCenterClient {
    /// Every request posted, in order.
    private(set) var posted: [UNNotificationRequest] = []
    /// What Notification Center would show now, by identifier (a newer
    /// request with the same identifier replaces the older one).
    private(set) var delivered: [String: UNNotificationRequest] = [:]
    /// Every identifier a removal named, in order.
    private(set) var removed: [String] = []
    var status: UNAuthorizationStatus = .authorized

    func install(delegate: UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>) {}
    func requestPermission(_ completion: @escaping (Bool, Error?) -> Void) { completion(status == .authorized, nil) }
    func authorization(_ completion: @escaping (UNAuthorizationStatus, UNAlertStyle) -> Void) { completion(status, .banner) }

    func post(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        posted.append(request)
        delivered[request.identifier] = request
        completion(nil)
    }

    func removeDelivered(_ identifiers: [String]) {
        removed += identifiers
        for identifier in identifiers { delivered[identifier] = nil }
    }

    func removePending(_ identifiers: [String]) {}
    func removeAllDelivered() { delivered.removeAll() }
    func removeAllPending() {}
    func deliveredIdentifiers(_ completion: @escaping ([String]) -> Void) { completion(Array(delivered.keys)) }
}

/// A session source whose observations a test sets between ticks.
final class ScriptedSource: SessionSource {
    let agent: Agent
    private let lock = NSLock()
    private var current: [Observation]

    init(_ agent: Agent, _ observations: [Observation] = []) {
        self.agent = agent
        current = observations
    }

    var observations: [Observation] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func poll(now: Date) -> [Observation] { observations }
}

/// Regressions found by review, driven through the real AppDelegate, engine,
/// tracker and Notifier. The notification center is a recorder, the sources
/// are scripted, routing is recorded: nothing is posted, opened or read
/// outside a scratch AI_SESSIONS_HOME.
@MainActor
final class AppRegressionTests: XCTestCase {
    private var home: URL!
    private var savedEnvironment: [String: String] = [:]
    private var center: RecordingCenter!
    private var routed: [TrackedSession] = []

    private let id = "9eb4895f-b5d9-41d0-8161-864ac0eecf46"
    private var key: SessionKey { SessionKey(agent: .claude, id: id) }
    private var configURL: URL { home.appendingPathComponent("config.json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sessions-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        for name in ["AI_SESSIONS_HOME", "AI_SESSIONS_CLAUDE_DIRS", "AI_SESSIONS_CODEX_HOMES"] {
            savedEnvironment[name] = environment[name]
        }
        // Belt and braces: the engine gets scripted sources anyway, but the
        // config it is built from must not name the real ~/.claude or ~/.codex.
        setenv("AI_SESSIONS_HOME", home.path, 1)
        setenv("AI_SESSIONS_CLAUDE_DIRS", home.appendingPathComponent("no-claude").path, 1)
        setenv("AI_SESSIONS_CODEX_HOMES", "", 1)
        routed = []
    }

    override func tearDown() {
        Log.shared.flush()
        for name in ["AI_SESSIONS_HOME", "AI_SESSIONS_CLAUDE_DIRS", "AI_SESSIONS_CODEX_HOMES"] {
            if let value = savedEnvironment[name] { setenv(name, value, 1) } else { unsetenv(name) }
        }
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    // MARK: Fixtures

    /// The app over `sources` and a scratch store, with a recording center and router.
    private func makeApp(_ sources: [SessionSource] = []) -> AppDelegate {
        let store = StateStore(url: home.appendingPathComponent("state/state.json"))
        let app = AppDelegate { config in SessionEngine(config: config, store: store, makeSources: { _ in sources }) }
        app.route = { [unowned self] session in self.routed.append(session) }
        center = RecordingCenter()
        app.install(Notifier(center: center))
        return app
    }

    /// One real tick (engine queue, then delivery on the main queue).
    private func tickAndWait(_ app: AppDelegate, file: StaticString = #filePath, line: UInt = #line) {
        app.tick()
        let deadline = Date().addingTimeInterval(5)
        while app.tickInFlight, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertFalse(app.tickInFlight, "the tick was never delivered", file: file, line: line)
    }

    private func claude(_ state: ActivityState, since: Date, rawStatus: String? = nil) -> Observation {
        Observation(key: key, state: state, rawStatus: rawStatus, stateSince: since, title: "AI Track",
                    cwd: "/work/coreOS", pid: 4242, entrypoint: "claude-vscode",
                    lastMessage: "May I run the migration?", host: .vscode(extensionHostPid: 3819))
    }

    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    // MARK: [4] [10] A banner whose session stopped needing you

    /// [4] Claude asks, the user answers "No" in the editor: waiting → idle,
    /// which the tracker records as read without an event.
    func testANeedsInputBannerIsWithdrawnWhenTheQuestionIsDealtWithWithoutResuming() {
        let now = Date()
        let source = ScriptedSource(.claude, [claude(.running, since: now.addingTimeInterval(-60))])
        let app = makeApp([source])
        tickAndWait(app) // first run: adopted silently

        source.observations = [claude(.waiting, since: now.addingTimeInterval(-5))]
        tickAndWait(app)
        XCTAssertEqual(center.posted.map(\.identifier), [key.description], "the question is announced")
        XCTAssertNotNil(center.delivered[key.description])

        source.observations = [claude(.idle, since: now)]
        tickAndWait(app)
        XCTAssertEqual(app.sessions.first?.unread, false, "the tracker counts the question as dealt with")
        XCTAssertNil(center.delivered[key.description],
                     "the 'needs your input' banner must go once the session stops waiting")
    }

    /// [10] A Codex thread waiting on an approval is stopped (turn_aborted):
    /// the delivered list says it no longer needs you, and no event says so.
    func testABannerIsWithdrawnWhenItsSessionStopsNeedingYouWithoutAnEvent() {
        let app = makeApp()
        let waiting = AppFixtures.session("019a0c2d", .waiting, agent: .codex, unread: true, title: "Rebase")
        app.deliver(.init(sessions: [waiting], events: [.needsInput(waiting)]))
        XCTAssertNotNil(center.delivered["codex:019a0c2d"])

        var aborted = waiting
        aborted.state = .idle
        aborted.rawStatus = "turn_aborted"
        aborted.unread = false
        app.deliver(.init(sessions: [aborted], events: []))
        XCTAssertNil(center.delivered["codex:019a0c2d"],
                     "a banner for a session that no longer needs you describes a state that is over")
    }

    /// Guard for the rule above: a banner posted this very tick stays, even
    /// when the list (ticked under other settings) does not count it as unread.
    func testABannerPostedThisTickIsNotWithdrawnByTheSameTick() {
        let app = makeApp()
        let waiting = AppFixtures.session("a1", .waiting, unread: true)
        app.deliver(.init(sessions: [waiting], events: [.needsInput(waiting)]))

        let finished = AppFixtures.session("a1", .idle, unread: false, lastTurn: 600)
        app.deliver(.init(sessions: [finished], events: [.finished(finished)]))
        XCTAssertEqual(center.delivered["claude:a1"]?.content.subtitle, "Claude · coreOS · done in 10m")
    }

    /// Guard: sessions that still need you keep their banners.
    func testBannersOfSessionsThatStillNeedYouStay() {
        let app = makeApp()
        let done = AppFixtures.session("d1", .idle, unread: true, lastTurn: 120)
        let waiting = AppFixtures.session("w1", .waiting, unread: true)
        app.deliver(.init(sessions: [waiting, done], events: [.needsInput(waiting), .finished(done)]))
        app.deliver(.init(sessions: [waiting, done], events: []))
        XCTAssertEqual(Set(center.delivered.keys), ["claude:w1", "claude:d1"])
        XCTAssertTrue(center.removed.isEmpty, "\(center.removed)")
    }

    // MARK: [11] Ended sessions keep their banners

    func testAnEndedSessionKeepsItsBannerAndAClickStillRoutesToIt() {
        let app = makeApp()
        let done = AppFixtures.session("e1", .idle, unread: true, lastTurn: 240)
        app.deliver(.init(sessions: [done], events: [.finished(done)]))
        XCTAssertNotNil(center.delivered["claude:e1"])

        app.deliver(.init(sessions: [], events: [.ended(done.key)])) // the VS Code window reloaded
        XCTAssertNotNil(center.delivered["claude:e1"], "a window reload must not erase an unread result")

        app.open(done.key)
        XCTAssertEqual(routed.map(\.key), [done.key])
        XCTAssertEqual(routed.first?.cwd, "/work/coreOS", "routed from the session's last known view")
    }

    func testTheNotifierDoesNotWithdrawOnEnded() {
        let center = RecordingCenter()
        let notifier = Notifier(center: center)
        let done = AppFixtures.session("e2", .idle, unread: true, lastTurn: 240)
        notifier.handle([.finished(done)], config: Config(), paused: false)
        notifier.handle([.ended(done.key)], config: Config(), paused: false)
        XCTAssertEqual(center.removed, [], ".ended must leave the banner alone")
        XCTAssertNotNil(center.delivered["claude:e2"])
    }

    // MARK: [8] [15] A click that arrives before the first tick

    /// The click that launched the app arrives before the first tick has
    /// listed anything: it must still route with the live session's host and
    /// pid (the window id comes from them), not with the placeholder.
    func testAClickBeforeTheFirstTickRoutesWithTheLiveSession() {
        let source = ScriptedSource(.claude, [claude(.idle, since: Date().addingTimeInterval(-30))])
        let app = makeApp([source])

        app.open(key)
        tickAndWait(app)

        XCTAssertEqual(routed.map(\.key), [key], "routed exactly once")
        XCTAssertEqual(routed.first?.pid, 4242, "the live Claude process, not the placeholder's nil")
        XCTAssertEqual(routed.first?.host, .vscode(extensionHostPid: 3819),
                       "the live extension host is what finds the owning window")
    }

    /// Guard: a queued click on a session nobody lists any more still routes
    /// (the placeholder deep link reopens it) once the first tick is in.
    func testAClickBeforeTheFirstTickOnAnUnknownSessionStillRoutes() {
        let app = makeApp([ScriptedSource(.claude)])
        let gone = SessionKey(agent: .codex, id: "01a0c894-49df-7102-92b1-6cf77abbf88e")

        app.open(gone)
        tickAndWait(app)

        XCTAssertEqual(routed.map(\.key), [gone])
        XCTAssertEqual(routed.first?.host, .vscode(extensionHostPid: nil))
    }

    // MARK: [12] Test notifications

    /// A finished, unread session with its real "done" banner up.
    private func appWithAnUnreadSession() -> AppDelegate {
        let now = Date()
        let source = ScriptedSource(.claude, [claude(.running, since: now.addingTimeInterval(-130))])
        let app = makeApp([source])
        tickAndWait(app) // first run: adopted silently
        source.observations = [claude(.idle, since: now.addingTimeInterval(-10))]
        tickAndWait(app) // finished after 2 minutes: announced, unread
        return app
    }

    func testATestBannerHasItsOwnIdentifierAndAClickOnItLeavesTheSessionUnread() throws {
        let app = appWithAnUnreadSession()
        XCTAssertEqual(app.sessions.first?.unread, true)
        let real = try XCTUnwrap(center.delivered[key.description])

        app.sendTestNotification(query: "")

        let sample = try XCTUnwrap(center.posted.last)
        XCTAssertEqual(sample.identifier, "test:\(key)", "a sample banner must not replace the session's real one")
        XCTAssertEqual(sample.content.userInfo["key"] as? String, key.description, "it still routes to the session")
        XCTAssertTrue(center.delivered[key.description] === real, "the real banner is still up")

        try XCTUnwrap(app.notifier).respond(action: UNNotificationDefaultActionIdentifier, identifier: sample.identifier,
                                            key: sample.content.userInfo["key"] as? String)
        tickAndWait(app)
        XCTAssertEqual(routed.map(\.key), [key], "a click on the sample routes")
        XCTAssertEqual(app.sessions.first?.unread, true, "but must not mark the session read")
        XCTAssertNotNil(center.delivered[key.description], "nor take its real banner away")
    }

    func testATestRequestLeftWhileTheAppWasNotRunningIsDroppedNotPosted() throws {
        let app = appWithAnUnreadSession()
        let posted = center.posted.count
        let trigger = AppDelegate.testTriggerURL
        try FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true)
        try Data("\n".utf8).write(to: trigger)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)],
                                              ofItemAtPath: trigger.path)

        app.housekeepIfDue(now: Date().addingTimeInterval(6))

        XCTAssertEqual(center.posted.count, posted, "a request from 2 minutes ago must not pop up a banner now")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trigger.path), "the stale request is consumed")
    }

    func testAFreshTestRequestPostsTheSample() throws {
        let app = appWithAnUnreadSession()
        try FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true)
        try Data("claude:9eb4\n".utf8).write(to: AppDelegate.testTriggerURL)

        app.housekeepIfDue(now: Date().addingTimeInterval(6))

        XCTAssertEqual(center.posted.last?.content.subtitle, "Claude · coreOS · test notification")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppDelegate.testTriggerURL.path))
    }

    // MARK: [7] An invalid config.json

    private let quiet = #"{"notificationsEnabled": false, "sound": false, "minTurnSecondsToNotify": 600}"#

    func testAnEditThatBreaksConfigJSONKeepsTheRunningSettings() throws {
        try writeConfig(quiet)
        let app = makeApp()
        XCTAssertEqual(app.config.notificationsEnabled, false, "loaded at launch")

        // A note above the settings: JSONDecoder accepts a trailing comma, not a comment.
        try writeConfig("// quiet while I am presenting\n" + quiet)
        app.housekeepIfDue(now: Date().addingTimeInterval(6))

        XCTAssertEqual(app.config.notificationsEnabled, false, "notifications the user turned off came back on")
        XCTAssertEqual(app.config.sound, false, "the sound the user turned off came back on")
        XCTAssertEqual(app.config.minTurnSecondsToNotify, 600, "the threshold went back to the default")
    }

    func testALaunchWithABrokenConfigJSONUsesTheLastGoodSettings() throws {
        try writeConfig(quiet)
        _ = makeApp() // a launch that read it fine

        try writeConfig(#"{"notificationsEnabled": false, "sound": false"#) // an unclosed brace
        let relaunched = makeApp()

        XCTAssertEqual(relaunched.config.notificationsEnabled, false, "a broken file must not turn notifications back on")
        XCTAssertEqual(relaunched.config.minTurnSecondsToNotify, 600)
    }

    /// The menu says so while the file is broken, and the fix takes effect.
    func testABrokenConfigJSONIsShownUntilItIsFixed() throws {
        try writeConfig(quiet)
        let app = makeApp()
        XCTAssertNil(app.configProblem)
        let lastGood = Config.lastGoodURL()
        XCTAssertEqual(try Data(contentsOf: lastGood), Data(quiet.utf8), "a launch keeps the copy")

        try writeConfig("{\"sound\": tru")
        app.housekeepIfDue(now: Date().addingTimeInterval(6))
        XCTAssertEqual(app.configProblem?.menuTitle, "config.json has an error — using previous settings")
        XCTAssertEqual(try Data(contentsOf: lastGood), Data(quiet.utf8), "a broken file is never kept")

        let fixed = #"{"sound": true, "minTurnSecondsToNotify": 30}"#
        try writeConfig(fixed)
        app.housekeepIfDue(now: Date().addingTimeInterval(12))
        XCTAssertNil(app.configProblem, "the row goes once the file reads again")
        XCTAssertEqual(app.config.minTurnSecondsToNotify, 30)
        XCTAssertEqual(app.config.notificationsEnabled, true, "a key the fixed file leaves out is back at its default")
        XCTAssertEqual(try Data(contentsOf: lastGood), Data(fixed.utf8))

        try FileManager.default.removeItem(at: configURL)
        app.housekeepIfDue(now: Date().addingTimeInterval(18))
        XCTAssertEqual(app.config, Config.load(), "no file: the defaults")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lastGood.path), "and the copy of the old file is gone")
    }

    func testALaunchWithABrokenFileAndNoGoodCopySaysItRunsOnTheDefaults() throws {
        try writeConfig("{")
        let app = makeApp()
        XCTAssertEqual(app.config.minTurnSecondsToNotify, Config().minTurnSecondsToNotify)
        XCTAssertEqual(app.configProblem?.menuTitle, "config.json has an error — using default settings")
        XCTAssertEqual(app.configProblem?.reason.hasPrefix("not valid JSON"), true, app.configProblem?.reason ?? "")
    }

    /// The sample's "Mark as Read" button is an explicit request.
    func testMarkAsReadOnASampleStillMarksTheSessionRead() throws {
        let app = appWithAnUnreadSession()
        app.sendTestNotification(query: "")
        let sample = try XCTUnwrap(center.posted.last)

        try XCTUnwrap(app.notifier).respond(action: Notifier.Action.markRead, identifier: sample.identifier,
                                            key: sample.content.userInfo["key"] as? String)
        tickAndWait(app)
        XCTAssertEqual(app.sessions.first?.unread, false)
        XCTAssertTrue(routed.isEmpty, "Mark as Read does not route")
    }
}
