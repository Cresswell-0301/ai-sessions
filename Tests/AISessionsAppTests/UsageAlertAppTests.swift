import AISessionsCore
import UserNotifications
import XCTest
@testable import AISessions

/// Usage-limit alerts through the real app: the poll, the banner, the
/// Telegram send, the click and the menu. Nothing is posted or sent: the
/// notification center records, Telegram is a closure, the dashboard a fixture.
@MainActor
final class UsageAlertAppTests: XCTestCase {
    private var home: URL!
    private var savedHome: String?
    private var center: RecordingCenter!
    private var sent: [(settings: TelegramSettings, html: String)] = []
    /// What the fake Telegram answers; nil = delivered.
    private var telegramFailure: TelegramError?
    private var clockNow = Date(timeIntervalSince1970: 1_791_600_000)
    private let token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("usage-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        setenv("AI_SESSIONS_HOME", home.path, 1)
        sent = []
        telegramFailure = nil
    }

    override func tearDown() {
        Log.shared.flush()
        if let savedHome { setenv("AI_SESSIONS_HOME", savedHome, 1) } else { unsetenv("AI_SESSIONS_HOME") }
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    // MARK: Fixtures

    /// Mutable answer for the fake dashboard; the monitor asks it off the
    /// main actor, hence the lock.
    private final class Dashboard: @unchecked Sendable {
        private let lock = NSLock()
        private var _body: Data?
        private var _asked: [URL] = []
        var body: Data? {
            get { lock.withLock { _body } }
            set { lock.withLock { _body = newValue } }
        }
        var asked: [URL] { lock.withLock { _asked } }
        var calls: Int { asked.count }

        func answer(_ url: URL) -> Data? {
            lock.withLock {
                _asked.append(url)
                return _body
            }
        }
    }

    private func dashboardJSON(trimoWeekly: Double, trimoSession: Double = 28,
                               cresswellSession: Double = 65, cresswellWeekly: Double = 44) -> Data {
        func row(_ label: String, session: Double, weekly: Double) -> [String: Any] {
            ["tool": "claude", "label": label, "skipped": "signed in — no usage recorded yet", "limits": ["error": NSNull(), "windows": [
                ["kind": "session", "label": "Session (5hr)", "pct": session, "resets": 1_791_610_000],
                ["kind": "weekly_all", "label": "Weekly (7 day)", "pct": weekly, "resets": 1_791_800_000],
            ]] as [String: Any]]
        }
        // CoreOS is maxed out from before, like six accounts on the real
        // dashboard: the first reading must record it, not announce it.
        return try! JSONSerialization.data(withJSONObject: ["rows": [
            row("trimo", session: trimoSession, weekly: trimoWeekly),
            row("cresswell-nexxatech", session: cresswellSession, weekly: cresswellWeekly),
            row("CoreOS", session: 0, weekly: 100),
        ]])
    }

    private func makeApp() -> AppDelegate {
        let store = StateStore(url: home.appendingPathComponent("state/state.json"))
        let app = AppDelegate { config in SessionEngine(config: config, store: store, makeSources: { _ in [] }) }
        center = RecordingCenter()
        app.install(Notifier(center: center))
        app.sendTelegram = { [unowned self] settings, html in
            if let failure = self.telegramFailure { throw failure }
            self.sent.append((settings, html))
        }
        app.clock = { [unowned self] in self.clockNow }
        return app
    }

    /// Lets the send under way finish.
    private func settle(_ app: AppDelegate) async {
        await app.telegramTask?.value
    }

    /// The monitor on the test's clock: the fixture's resets lie ahead of it.
    /// `delay` holds each answer back, as a dashboard busy rescanning does.
    private func monitor(for app: AppDelegate, _ dashboard: Dashboard, delay: UInt64 = 0) -> UsageMonitor {
        UsageMonitor(config: app.config,
                     engine: UsageAlertEngine(url: home.appendingPathComponent("state/usage-alerts.json"), threshold: 90),
                     fetch: { url in
                         let body = dashboard.answer(url)
                         if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                         guard let body else { throw URLError(.cannotConnectToHost) }
                         return body
                     },
                     now: { [unowned self] in clockNow })
    }

    private func connectTelegram() throws {
        try TelegramSettings(botToken: token, chatId: 222, botUsername: "my_usage_bot", chatName: "Cress").save()
    }

    // MARK: The path of an alert

    func testACrossingPostsOneBannerAndOneTelegramMessage() async throws {
        try connectTelegram()
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 85)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll() // first reading: CoreOS at 100% is recorded, not announced
        XCTAssertEqual(center.posted.count, 0, "an account maxed out before the app started is not news")
        XCTAssertTrue(sent.isEmpty)

        dashboard.body = dashboardJSON(trimoWeekly: 94)
        await monitor.poll()
        await settle(app)
        XCTAssertEqual(center.posted.map(\.identifier), ["usage:claude|trimo|weekly_all"])
        let content = try XCTUnwrap(center.posted.first?.content)
        XCTAssertEqual(content.title, "trimo: Claude weekly limit at 94%")
        XCTAssertEqual(content.categoryIdentifier, Notifier.usageCategoryIdentifier)
        XCTAssertEqual(content.userInfo["openURL"] as? String, "http://127.0.0.1:8787")
        XCTAssertTrue(content.body.contains("cresswell-nexxatech"), content.body)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.settings.chatId, 222)
        XCTAssertTrue(sent.first?.html.contains("<b>trimo</b> — Claude weekly at <b>94%</b>") ?? false, sent.first?.html ?? "")

        await monitor.poll() // still over: nothing new
        await settle(app)
        XCTAssertEqual(center.posted.count, 1)
        XCTAssertEqual(sent.count, 1)
    }

    func testPauseSilencesTheBannerButNotTelegram() async throws {
        try connectTelegram()
        try Data("paused".utf8).write(to: PauseFlag.standard.url)
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 92)
        await monitor.poll()
        await settle(app)
        XCTAssertEqual(center.posted.count, 0, "paused: no banner")
        XCTAssertEqual(sent.count, 1, "the phone still hears about a limit")
    }

    func testWithoutTelegramOnlyTheBanner() async {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 92)
        await monitor.poll()
        await settle(app)
        XCTAssertEqual(center.posted.count, 1)
        XCTAssertTrue(sent.isEmpty, "nothing to send to before a bot is connected")
        XCTAssertTrue(app.telegramOutbox.pending.isEmpty, "nor anything kept for later")
    }

    func testAnUnreachableDashboardKeepsTheLastReadingAndSaysWhy() async {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = nil
        await monitor.poll()
        XCTAssertNotNil(monitor.status.snapshot, "the last good reading stays")
        XCTAssertEqual(monitor.status.problem, "the usage dashboard is not reachable at http://127.0.0.1:8787")
        let state = UsageMenu.State(status: monitor.status)
        XCTAssertEqual(UsageMenu.title(state, now: clockNow), "Usage limits — 1 at 90%+ (last known)")
    }

    // MARK: When Telegram fails

    /// An app past its first reading, one poll away from trimo's crossing.
    private func appBeforeACrossing() async throws -> (AppDelegate, UsageMonitor, Dashboard) {
        try connectTelegram()
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 93)
        return (app, monitor, dashboard)
    }

    func testAnUnreachableTelegramGetsTheAlertLaterAndTheMenuSaysWhy() async throws {
        let (app, monitor, _) = try await appBeforeACrossing()
        telegramFailure = TelegramError("Could not reach Telegram (-1009): check the connection", kind: .transient)
        await monitor.poll()
        await settle(app)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(app.telegramOutbox.pending.count, 1, "kept for another try")
        XCTAssertEqual(center.posted.map(\.identifier), ["usage:claude|trimo|weekly_all"], "no banner for a passing failure")
        let state = app.usageMenuState()
        XCTAssertEqual(UsageMenu.telegramLines(state, now: clockNow), [
            "Telegram: not delivering — @my_usage_bot → Cress",
            "Could not reach Telegram (-1009): check the connection",
            "1 alert waits to be sent — next try in 1m",
        ])

        // Housekeeping (every 5 s) is what tries again.
        telegramFailure = nil
        clockNow += 10
        app.housekeepIfDue(now: clockNow)
        await settle(app)
        XCTAssertTrue(sent.isEmpty, "not before its pause is over")
        clockNow += 21
        app.housekeepIfDue(now: clockNow)
        await settle(app)
        XCTAssertEqual(sent.count, 1, "delivered once Telegram answers")
        XCTAssertTrue(sent.first?.html.hasPrefix("⚠️ <b>AI usage — limit almost hit</b>\n• <b>trimo</b> — Claude weekly at <b>93%</b>") ?? false,
                      "31 s late is not worth a note: " + (sent.first?.html ?? ""))
        XCTAssertTrue(app.telegramOutbox.pending.isEmpty)
        XCTAssertEqual(UsageMenu.telegramLines(app.usageMenuState(), now: clockNow), ["Telegram: @my_usage_bot → Cress"])
    }

    func testARefusedAlertPostsOneBannerThatOpensTheBot() async throws {
        let (app, monitor, dashboard) = try await appBeforeACrossing()
        telegramFailure = TelegramError("Telegram refused (Forbidden: bot was blocked by the user). Open the chat with your bot and press Start.")
        await monitor.poll()
        await settle(app)
        XCTAssertTrue(app.telegramOutbox.pending.isEmpty, "a refusal is not retried")
        let banners = center.posted.filter { $0.identifier == "usage:telegram" }
        XCTAssertEqual(banners.count, 1)
        XCTAssertEqual(banners.first?.content.title, "A usage alert did not reach Telegram")
        XCTAssertEqual(banners.first?.content.body, telegramFailure?.message)
        XCTAssertEqual(banners.first?.content.userInfo["openURL"] as? String, "https://t.me/my_usage_bot")

        // The next crossing fails the same way: no second banner for it.
        dashboard.body = dashboardJSON(trimoWeekly: 93, trimoSession: 95)
        await monitor.poll()
        await settle(app)
        XCTAssertEqual(center.posted.filter { $0.identifier == "usage:telegram" }.count, 1, "one banner per problem")
        XCTAssertEqual(center.posted.filter { $0.identifier.hasPrefix("usage:claude") }.count, 2, "the usage banners still come")
    }

    func testAnAlertLeftByARestartIsSentAfterIt() async throws {
        try connectTelegram()
        TelegramOutbox.standard().enqueue("⚠️ left from before", now: clockNow)
        clockNow += 3600 // the Mac slept through it
        let app = makeApp()
        app.housekeepIfDue(now: clockNow)
        await settle(app)
        XCTAssertEqual(sent.count, 1)
        let html = sent.first?.html ?? ""
        XCTAssertTrue(html.hasPrefix("⏱ <i>Delayed: this alert is from ") && html.hasSuffix(".</i>\n⚠️ left from before"),
                      "an hour-old table says how old it is: \(html)")
    }

    func testTurningTelegramOffOrDisconnectingDropsWhatWaits() async throws {
        let (app, monitor, _) = try await appBeforeACrossing()
        telegramFailure = TelegramError("Could not reach Telegram", kind: .transient)
        await monitor.poll()
        await settle(app)
        XCTAssertEqual(app.telegramOutbox.pending.count, 1)
        TelegramSettings.delete()
        clockNow += 60
        app.housekeepIfDue(now: clockNow)
        await settle(app)
        XCTAssertTrue(app.telegramOutbox.pending.isEmpty, "nobody to send it to any more")
        XCTAssertNil(app.telegramOutbox.problem)
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: Settings that change while a poll waits

    func testTurningAlertsOffWhileAPollWaitsAnnouncesNothing() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard, delay: 300_000_000)
        var announced: [[UsageAlert]] = []
        monitor.onAlerts = { alerts, _ in announced.append(alerts) }
        await monitor.poll() // first reading
        dashboard.body = dashboardJSON(trimoWeekly: 95)
        let poll = Task { await monitor.poll() }
        while dashboard.calls < 2 { await Task.yield() } // waiting on the dashboard now
        var off = monitor.config
        off.usageAlertsEnabled = false
        monitor.apply(off)
        await poll.value
        XCTAssertTrue(announced.isEmpty, "alerts were off by the time this reading came")
        XCTAssertNil(monitor.status.snapshot, "and the menu stays cleared")
    }

    func testADashboardMovedWhileAPollWaitsIsAskedAgain() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard, delay: 300_000_000)
        let poll = Task { await monitor.poll() }
        while dashboard.calls < 1 { await Task.yield() }
        var moved = monitor.config
        moved.usageDashboardURL = "http://127.0.0.1:9797"
        monitor.apply(moved)
        await poll.value
        XCTAssertNil(monitor.status.snapshot, "the old dashboard's answer is dropped")
        let deadline = Date().addingTimeInterval(5)
        while monitor.status.snapshot == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(dashboard.asked.map(\.absoluteString),
                       ["http://127.0.0.1:8787/data.json", "http://127.0.0.1:9797/data.json"], "then the new one is asked")
        XCTAssertNotNil(monitor.status.snapshot)
    }

    // MARK: Banners

    func testEachMultiCrossingBannerStaysAndMarkAllReadLeavesThem() async throws {
        try connectTelegram()
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 93, trimoSession: 95)
        await monitor.poll() // trimo's session and week together
        dashboard.body = dashboardJSON(trimoWeekly: 93, trimoSession: 95, cresswellSession: 97, cresswellWeekly: 91)
        await monitor.poll() // then cresswell's, together too
        await settle(app)
        let usage = center.delivered.keys.filter { $0.hasPrefix("usage:") }.sorted()
        XCTAssertEqual(usage, ["usage:several:claude|cresswell-nexxatech|session,claude|cresswell-nexxatech|weekly_all",
                               "usage:several:claude|trimo|session,claude|trimo|weekly_all"],
                       "the second pair's banner does not replace the first's")
        center.post(UNNotificationRequest(identifier: "claude:9eb4895f-b5d9-41d0-8161-864ac0eecf46",
                                          content: UNMutableNotificationContent(), trigger: nil)) { _ in }
        app.notifier?.withdrawAll() // Mark All as Read
        XCTAssertEqual(center.delivered.keys.sorted(), usage, "session banners go, usage alerts stay")
    }

    // MARK: Setting up

    func testOnlyOneSetupRunsAtATime() async {
        var release: CheckedContinuation<Void, Never>?
        var finished: [TelegramSettings?] = []
        let flow: @MainActor () async -> TelegramSettings? = {
            await withCheckedContinuation { release = $0 }
            return nil
        }
        XCTAssertTrue(TelegramSetup.run(flow, completion: { finished.append($0) }))
        XCTAssertTrue(TelegramSetup.isRunning)
        XCTAssertFalse(TelegramSetup.run(flow, completion: { finished.append($0) }), "a second click while one is open")
        XCTAssertEqual(StatusMenuController.setUpTitle(UsageMenu.State(settingUpTelegram: TelegramSetup.isRunning)),
                       "Setting Up Telegram…")
        while release == nil { await Task.yield() }
        release?.resume()
        while TelegramSetup.isRunning { await Task.yield() }
        XCTAssertEqual(finished.count, 1)
        XCTAssertTrue(TelegramSetup.run({ nil }, completion: { _ in }), "free again once it ends")
        while TelegramSetup.isRunning { await Task.yield() }
    }

    func testTheHiddenEditMenuGivesTheTokenFieldPaste() throws {
        let menu = AppMenu.make()
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu)
        let items = Dictionary(uniqueKeysWithValues: edit.items.compactMap { item in item.action.map { (NSStringFromSelector($0), item) } })
        for (action, key) in ["paste:": "v", "copy:": "c", "cut:": "x", "selectAll:": "a", "undo:": "z"] {
            let item = try XCTUnwrap(items[action], "\(action) is missing")
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, .command)
            XCTAssertNil(item.target, "\(action) goes to the focused field, whatever it is")
        }
        XCTAssertNotEqual(menu.items.first?.title, "Edit", "the first item is the application menu")
    }

    // MARK: Clicks and housekeeping

    func testAClickOnAUsageBannerOpensTheDashboard() {
        let notifier = Notifier(center: RecordingCenter())
        var opened: [URL] = []
        notifier.onOpenURL = { opened.append($0) }
        notifier.respond(action: UNNotificationDefaultActionIdentifier, openURL: "http://127.0.0.1:8787")
        notifier.respond(action: Notifier.Action.openDashboard, openURL: "http://127.0.0.1:8787")
        notifier.respond(action: UNNotificationDismissActionIdentifier, openURL: "http://127.0.0.1:8787")
        notifier.respond(action: UNNotificationDefaultActionIdentifier, openURL: "file:///etc/passwd")
        XCTAssertEqual(opened.map(\.absoluteString), ["http://127.0.0.1:8787", "http://127.0.0.1:8787"],
                       "dismissing opens nothing; only web pages open")
    }

    func testStartupCleanupKeepsUsageBanners() {
        let center = RecordingCenter()
        let notifier = Notifier(center: center)
        let content = UNMutableNotificationContent()
        for id in ["usage:claude|trimo|weekly_all", "claude:9eb4895f-b5d9-41d0-8161-864ac0eecf46"] {
            center.post(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
        }
        notifier.removeDelivered(keeping: [])
        XCTAssertEqual(Array(center.delivered.keys), ["usage:claude|trimo|weekly_all"])
    }

    // MARK: Menu words

    func testTelegramMenuLines() {
        let now = clockNow
        var state = UsageMenu.State()
        XCTAssertEqual(UsageMenu.telegramLines(state, now: now), [], "not connected: only the setup item")
        XCTAssertEqual(StatusMenuController.setUpTitle(state), "Set Up Telegram Alerts…")
        state.telegram = "@my_usage_bot → Cress"
        XCTAssertEqual(UsageMenu.telegramLines(state, now: now), ["Telegram: @my_usage_bot → Cress"])
        state.telegramProblem = "Telegram did not accept the bot token (Unauthorized). Copy it again from @BotFather."
        state.telegramWaiting = 2
        state.telegramNextTry = now.addingTimeInterval(-1)
        XCTAssertEqual(UsageMenu.telegramLines(state, now: now), [
            "Telegram: not delivering — @my_usage_bot → Cress",
            "Telegram did not accept the bot token (Unauthorized). Copy it again from @BotFather.",
            "2 alerts wait to be sent — sending",
        ])
        XCTAssertEqual(StatusMenuController.setUpTitle(state), "Set Up Telegram Again…")
        state.telegramEnabled = false
        XCTAssertEqual(UsageMenu.telegramLines(state, now: now), ["Telegram: off (telegramAlerts in config.json)"])
    }

    func testUsageMenuTitles() {
        let now = clockNow
        var state = UsageMenu.State()
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — checking…")
        state.status.problem = "the usage dashboard is not reachable at http://127.0.0.1:8787"
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — dashboard not reachable")
        state.status = UsageMonitor.Status(snapshot: UsageSnapshot.parse(dashboardJSON(trimoWeekly: 94), fetchedAt: now))
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — 2 at 90%+")
        XCTAssertEqual(UsageMenu.topSymbol(state).name, "exclamationmark.triangle.fill")
        XCTAssertEqual(UsageMenu.sorted(state.status.snapshot!.accounts).map(\.label),
                       ["CoreOS", "trimo", "cresswell-nexxatech"], "fullest first")
        XCTAssertEqual(UsageMenu.freshness(state, now: now), "Updated just now")
        state.enabled = false
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — alerts off")
        for name in ["gauge.with.dots.needle.33percent", "exclamationmark.triangle.fill", "questionmark.circle"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) must exist")
        }
    }
}
