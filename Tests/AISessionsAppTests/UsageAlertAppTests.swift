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
    private var sent: [(settings: TelegramSettings, html: String, markup: TelegramMarkup?)] = []
    /// What the fake Telegram answers; nil = delivered.
    private var telegramFailure: TelegramError?
    private var clockNow = Date(timeIntervalSince1970: 1_791_600_000)
    private let token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("usage-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        setenv("AI_SESSIONS_HOME", home.path, 1)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try signIn("trimo") // the account the tests' sessions use
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
                               cresswellSession: Double = 65, cresswellWeekly: Double = 44, trimoEmail: Bool = true) -> Data {
        func row(_ label: String, session: Double, weekly: Double) -> [String: Any] {
            ["tool": "claude", "label": label,
             "email": label == "trimo" && !trimoEmail ? NSNull() : "\(label.lowercased())@example.com" as Any,
             "skipped": "signed in — no usage recorded yet",
             "limits": ["error": NSNull(), "as_of": 1_791_599_940, "windows": [
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
        app.sendTelegram = { [unowned self] settings, html, markup in
            if let failure = self.telegramFailure { throw failure }
            self.sent.append((settings, html, markup))
        }
        app.clock = { [unowned self] in self.clockNow }
        return app
    }

    /// Lets the send under way finish.
    private func settle(_ app: AppDelegate) async {
        await app.telegramTask?.value
    }

    /// The monitor on the test's clock (the fixture's resets lie ahead of it),
    /// reading who is signed in from the scratch home's `~/.claude.json`.
    /// `delay` holds each answer back, as a dashboard busy rescanning does.
    private func monitor(for app: AppDelegate, _ dashboard: Dashboard, delay: UInt64 = 0,
                         alertAccounts: [String]? = nil, excludeFile: URL? = nil, configDirs: [URL]? = nil) -> UsageMonitor {
        var config = app.config
        if let alertAccounts { config.usageAlertAccounts = alertAccounts }
        // Never the real ~/.ai-accounts file in a test.
        config.usageExcludeFile = (excludeFile ?? home.appendingPathComponent("no-exclusions.json")).path
        let home = self.home!
        return UsageMonitor(config: config,
                            engine: UsageAlertEngine(url: home.appendingPathComponent("state/usage-alerts.json"), threshold: 90),
                            fetch: { url in
                                let body = dashboard.answer(url)
                                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                                guard let body else { throw URLError(.cannotConnectToHost) }
                                return body
                            },
                            now: { [unowned self] in clockNow },
                            accounts: { _ in SignedInAccounts(configDirs: configDirs ?? [home.appendingPathComponent(".claude")], home: home) })
    }

    /// Claude Code signed in as `label`'s account (nil: the file is gone).
    private func signIn(_ label: String?) throws {
        let file = home.appendingPathComponent(".claude.json")
        guard let label else { return try FileManager.default.removeItem(at: file) }
        let root: [String: Any] = ["numStartups": 9, "oauthAccount": ["emailAddress": "\(label.lowercased())@example.com"]]
        try JSONSerialization.data(withJSONObject: root).write(to: file, options: .atomic)
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
        XCTAssertEqual(content.title, "Claude weekly limit at 94%")
        XCTAssertEqual(content.categoryIdentifier, Notifier.usageCategoryIdentifier)
        XCTAssertEqual(content.userInfo["openURL"] as? String, "http://127.0.0.1:8787")
        XCTAssertEqual(content.subtitle, "trimo · renews in 2d 7h")
        XCTAssertEqual(content.body, "Use first: cresswell-nexxatech (35% left).", "the dashboard's own pick")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.settings.chatId, 222)
        let html = sent.first?.html ?? ""
        XCTAssertTrue(html.hasPrefix("⚠️ <b>trimo</b> — Claude weekly at <b>94%</b>\n\n<b>Claude Code</b>\n"), html)
        XCTAssertTrue(html.contains("trimo         28% 2h46m 94% 2d7h ⚠ ◀"), "with when each limit renews: \(html)")
        XCTAssertFalse(html.contains("Use first") || html.contains("Most usage left"), "no advice in Telegram: \(html)")
        XCTAssertEqual(sent.first?.markup, .usageNowButton, "a button under the alert for a fresh report")

        await monitor.poll() // still over: nothing new
        await settle(app)
        XCTAssertEqual(center.posted.count, 1)
        XCTAssertEqual(sent.count, 1)
    }

    func testAHiddenAccountsAlertReachesTheMacOnlyAndTelegramNeverNamesIt() async throws {
        try connectTelegram()
        try Data(#"{"telegramHiddenAccounts": ["trimo@example.com", "cresswell-nexxatech"]}"#.utf8)
            .write(to: home.appendingPathComponent("config.json"))
        let app = makeApp()
        XCTAssertEqual(app.config.telegramHiddenAccounts, ["trimo@example.com", "cresswell-nexxatech"])
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 85)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 94)
        await monitor.poll()
        await settle(app)
        XCTAssertEqual(center.posted.count, 1, "the Mac still hears about it")
        XCTAssertTrue(sent.isEmpty, "Telegram does not")
        XCTAssertTrue(app.telegramOutbox.pending.isEmpty)

        let reply = await app.usageReport()
        let report = try XCTUnwrap(reply)
        XCTAssertFalse(report.contains("trimo"), report)
        XCTAssertFalse(report.contains("cresswell"), report)
        XCTAssertTrue(report.contains("CoreOS"), report)
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
        XCTAssertEqual(UsageMenu.title(state, now: clockNow), "Usage limits — trimo at 50% weekly · 28% session (last known)")
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
        XCTAssertTrue(sent.first?.html.hasPrefix("⚠️ <b>trimo</b> — Claude weekly at <b>93%</b>") ?? false,
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

    // MARK: The account in use

    func testOnlyTheAccountInUseAlerts() async throws {
        try connectTelegram()
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 50, cresswellSession: 97, cresswellWeekly: 93)
        await monitor.poll()
        await settle(app)
        XCTAssertTrue(center.posted.isEmpty, "another account's limits are not this user's news")
        XCTAssertTrue(sent.isEmpty)
        dashboard.body = dashboardJSON(trimoWeekly: 92, cresswellSession: 97, cresswellWeekly: 93)
        await monitor.poll()
        await settle(app)
        XCTAssertEqual(center.posted.map(\.identifier), ["usage:claude|trimo|weekly_all"])
        let html = sent.first?.html ?? ""
        XCTAssertTrue(html.contains("trimo         28% 2h46m 92% 2d7h ⚠ ◀"), "the account in use is marked: \(html)")
        XCTAssertTrue(html.contains("cresswell-nex 97% 2h46m 93% 2d7h ⚠\n"), "and only it")
    }

    func testSigningInToAnAccountAlreadyOverTheLimitAlerts() async throws {
        try signIn("cresswell-nexxatech")
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50) // CoreOS sits at 100% weekly
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        await monitor.poll()
        XCTAssertTrue(center.posted.isEmpty)
        try signIn("CoreOS") // /login to the full account
        await monitor.poll()
        XCTAssertTrue(center.posted.isEmpty, "a new sign-in is followed once a second poll still sees it")
        await monitor.poll()
        XCTAssertEqual(center.posted.map { "\($0.content.title) / \($0.content.subtitle)" },
                       ["Claude weekly limit at 100% / CoreOS · renews in 2d 7h"], "the account now in use is already at its limit")
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "once")
        try signIn("cresswell-nexxatech")
        await monitor.poll()
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "back on an account with room: nothing to say")
    }

    func testTheDashboardsOptOutsAreHonoured() async throws {
        let file = home.appendingPathComponent("suggest-exclude.json")
        try Data(#"["claude:cresswell-nexxatech@example.com"]"#.utf8).write(to: file)
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard, excludeFile: file)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 94)
        await monitor.poll()
        XCTAssertEqual(center.posted.first?.content.body, "All near a limit; CoreOS frees up first.",
                       "cresswell-nexxatech is opted out on the dashboard: not where to go")
    }

    func testUnderEveryAccountASwitchIsNotNewsAgain() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard, alertAccounts: ["all"])
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 50, cresswellWeekly: 95)
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "cresswell crossed; every account is followed")
        try signIn("cresswell-nexxatech")
        for _ in 0..<3 { await monitor.poll() }
        XCTAssertEqual(center.posted.count, 1, "this Mac switched to it: the alert was already given")
    }

    func testNamedAccountsAlertWhileTheSignInCannotBeRead() async throws {
        try signIn(nil)
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard, alertAccounts: ["current", "cresswell-nexxatech"])
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 50, cresswellWeekly: 95)
        await monitor.poll()
        XCTAssertEqual(center.posted.map(\.identifier), ["usage:claude|cresswell-nexxatech|weekly_all"],
                       "a named account does not wait for Claude's sign-in")
        let state = UsageMenu.State(status: monitor.status)
        XCTAssertEqual(UsageMenu.followed(state), "Alerts for cresswell-nexxatech; no Claude sign-in found")
    }

    func testOneOfTwoConfigDirsLosingItsAccountBrieflyIsNotASwitch() async throws {
        let work = home.appendingPathComponent("profiles/work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["emailAddress": "cresswell-nexxatech@example.com"]])
            .write(to: work.appendingPathComponent(".claude.json"))
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard, configDirs: [home.appendingPathComponent(".claude"), work])
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 95)
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "trimo crossed")
        try signIn(nil) // a /login in ~/.claude, two polls long
        await monitor.poll()
        await monitor.poll()
        try signIn("trimo")
        for _ in 0..<3 { await monitor.poll() }
        XCTAssertEqual(center.posted.count, 1, "back to the same account: not a switch, not news")
    }

    func testWideningTheSettingAnnouncesNothingOld() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50) // CoreOS at 100% from before
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        var all = monitor.config
        all.usageAlertAccounts = ["all"]
        monitor.apply(all)
        await monitor.poll()
        await monitor.poll()
        XCTAssertTrue(center.posted.isEmpty, "CoreOS was at its limit before the first reading: not news under any setting")
    }

    func testANoReportReplySaysWhy() async throws {
        let app = makeApp()
        XCTAssertEqual(app.noReportReason(), "📊 No usage reading yet: the dashboard at http://127.0.0.1:8787 is not answering.")
        try Data(#"{"usageAlertsEnabled": false}"#.utf8).write(to: home.appendingPathComponent("config.json"))
        let off = makeApp()
        XCTAssertEqual(off.noReportReason(), "📊 Usage limits are off in AI Sessions (usageAlertsEnabled in config.json).")
    }

    func testUnderEveryAccountARowWithoutItsEmailIsStillTheSameAccount() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard, alertAccounts: ["all"])
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 95)
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1)
        dashboard.body = dashboardJSON(trimoWeekly: 95, trimoEmail: false) // the scan could not read trimo's profile
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "its address is remembered: the same account, the same crossing")
    }

    func testAReportAfterTheDashboardStoppedSaysHowOld() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = nil
        clockNow += 5 * 3600
        let report = await app.usageReport() ?? ""
        XCTAssertTrue(report.contains("⚠️ The dashboard is not answering: these numbers are from"), report)
        XCTAssertTrue(report.contains("(5h ago)"), report)
        XCTAssertFalse(report.contains("Use first"), "no advice: \(report)")
    }

    func testARowThatLosesItsEmailForAMomentIsNotAlertedTwice() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 95)
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1)
        dashboard.body = dashboardJSON(trimoWeekly: 95, trimoEmail: false) // one scan could not read the profile
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 95)
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "the same crossing: not news again")
    }

    func testSwitchingBackToAnAccountThatCrossedRemindsOnce() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 95)
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "trimo crossed")
        try signIn("cresswell-nexxatech")
        await monitor.poll()
        await monitor.poll()
        try signIn("trimo") // back, the same week
        await monitor.poll()
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 2, "back on an account at 95%: said again")
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 2, "once")
    }

    func testWhileNoSignInCanBeReadNothingIsEvaluated() async throws {
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        dashboard.body = dashboardJSON(trimoWeekly: 95)
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "trimo crossed")
        try signIn(nil) // ~/.claude.json gone (a login saves it without an account first)
        await monitor.poll()
        XCTAssertEqual(UsageMenu.title(UsageMenu.State(status: monitor.status), now: clockNow),
                       "Usage limits — trimo at 95% weekly · 28% session", "a moment without an account changes nothing")
        for _ in 0..<4 { await monitor.poll() }
        XCTAssertEqual(UsageMenu.title(UsageMenu.State(status: monitor.status), now: clockNow),
                       "Usage limits — can't tell which account is in use", "five polls without one: not known")
        try signIn("trimo")
        await monitor.poll()
        XCTAssertEqual(center.posted.count, 1, "trimo's alert was kept, not forgotten and repeated")
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
        let monitor = monitor(for: app, dashboard, alertAccounts: ["all"])
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

    // MARK: The Usage button

    /// Telegram for the bot: hands out queued updates to its long poll (a
    /// short wait when none), records every call.
    private final class FakeBotAPI: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [[String: Any]] = []
        private var _calls: [(method: String, body: [String: Any])] = []
        var backlogNewest: Int64?
        var getUpdatesStatus = 200
        /// Long polls that lose their connection before answering.
        var dropsLeft = 0

        var calls: [(method: String, body: [String: Any])] { lock.withLock { _calls } }
        func sent() -> [[String: Any]] { calls.filter { $0.method == "sendMessage" }.map(\.body) }
        func push(_ updates: [String: Any]...) { lock.withLock { queue += updates } }

        func transport() -> TelegramClient.Transport {
            { [self] request in
                let method = request.url!.lastPathComponent
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let dropped: Bool = lock.withLock {
                    guard method == "getUpdates", (body["offset"] as? NSNumber)?.intValue != -1, dropsLeft > 0 else { return false }
                    dropsLeft -= 1
                    _calls.append((method, body))
                    return true
                }
                if dropped { throw URLError(.networkConnectionLost) }
                let (result, status): (Any, Int) = lock.withLock {
                    _calls.append((method, body))
                    guard method == "getUpdates" else { return (true, 200) }
                    if getUpdatesStatus != 200 { return ([], getUpdatesStatus) }
                    if (body["offset"] as? NSNumber)?.intValue == -1 {
                        return (backlogNewest.map { [["update_id": NSNumber(value: $0)]] } ?? [], 200)
                    }
                    let out = queue
                    queue = []
                    return (out, 200)
                }
                if status != 200 {
                    return (Data(#"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8), status)
                }
                if method == "getUpdates", (result as? [Any])?.isEmpty == true {
                    try await Task.sleep(nanoseconds: 20_000_000) // a long poll that found nothing
                }
                return (try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), 200)
            }
        }
    }

    private func message(_ id: Int64, _ text: String, chat: Int64 = 222, name: String = "Cress") -> [String: Any] {
        ["update_id": id, "message": ["message_id": id, "date": clockNow.timeIntervalSince1970 - 2, "text": text,
                                      "chat": ["id": chat, "type": "private"], "from": ["id": chat, "first_name": name]]]
    }

    /// What the bot sent to `chat`, in order.
    private func texts(_ api: FakeBotAPI, to chat: Int64) -> [String] {
        api.sent().filter { ($0["chat_id"] as? NSNumber)?.int64Value == chat }.compactMap { $0["text"] as? String }
    }


    private func tap(_ id: Int64, chat: Int64 = 222) -> [String: Any] {
        ["update_id": id, "callback_query": ["id": "cb-\(id)", "data": "usage", "from": ["id": chat],
                                              "message": ["message_id": 7, "chat": ["id": chat, "type": "private"]]]]
    }

    /// Waits (up to 5 s) for `done`.
    private func until(_ what: String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// An app listening for the Usage button, trimo signed in, over a fake Telegram.
    private func listeningApp(_ api: FakeBotAPI) async throws -> (AppDelegate, TelegramBot) {
        try connectTelegram()
        let app = makeApp()
        let dashboard = Dashboard()
        dashboard.body = dashboardJSON(trimoWeekly: 50)
        let monitor = monitor(for: app, dashboard)
        app.startUsageMonitor(monitor)
        await monitor.poll()
        let bot = TelegramBot(transport: api.transport(), clock: { [unowned self] in clockNow })
        app.telegramBot = bot
        app.syncTelegramBot()
        try await until("the bot to listen") { api.calls.contains { $0.method == "getUpdates" && ($0.body["offset"] as? NSNumber)?.intValue != -1 } }
        return (app, bot)
    }

    func testTheUsageButtonGetsAReportBack() async throws {
        let api = FakeBotAPI()
        api.backlogNewest = 40 // a tap from before the app started
        let (app, bot) = try await listeningApp(api)
        defer { bot.stop(); withExtendedLifetime(app) {} } // the report comes from the app
        XCTAssertEqual(api.calls.first?.method, "getUpdates")
        XCTAssertEqual((api.calls.first?.body["offset"] as? NSNumber)?.intValue, -1, "what piled up is skipped")
        XCTAssertTrue(api.calls.contains { $0.method == "setMyCommands" }, "/usage is listed in the chat's menu")
        XCTAssertEqual(sent.first?.markup, .usageKeyboard, "a chat connected before the button gets it once")
        XCTAssertEqual(TelegramSettings.load()?.keyboardShown, true)

        api.push(message(41, "/usage", chat: 999, name: "Someone"), message(42, "📊 Usage"))
        try await until("two reports") { bot.answered == 2 }
        XCTAssertEqual(texts(api, to: 999).count, 1, "anyone who opens the bot gets one too")
        let reports = api.sent().filter { ($0["chat_id"] as? NSNumber)?.int64Value == 222 }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual((reports.first?["chat_id"] as? NSNumber)?.int64Value, 222)
        let text = reports.first?["text"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("📊 <b>AI usage</b> · "), text)
        XCTAssertTrue(text.contains("trimo         28% 2h46m 50% 2d7h ◀"), text)
        XCTAssertFalse(text.contains("Use first") || text.contains("Most usage left"), "no advice in Telegram: \(text)")
        let keyboard = reports.first?["reply_markup"] as? [String: Any]
        XCTAssertEqual(keyboard?["is_persistent"] as? Bool, true, "the button stays under the chat")
        let polls = api.calls.filter { $0.method == "getUpdates" }.compactMap { ($0.body["offset"] as? NSNumber)?.intValue }
        XCTAssertTrue(polls.contains(41), "listening starts after the skipped backlog: \(polls)")
    }

    func testAnyoneWhoOpensTheBotGetsAReportAtOnce() async throws {
        let api = FakeBotAPI()
        let (app, bot) = try await listeningApp(api)
        defer { bot.stop(); withExtendedLifetime(app) {} }
        api.push(message(50, "/start", chat: 555, name: "Lim Wei"))
        try await until("their report") { bot.answered == 1 }
        let first = try XCTUnwrap(texts(api, to: 555).first)
        XCTAssertTrue(first.hasPrefix("👋 Tap <b>📊 Usage</b> below any time for the latest.\n\n📊 <b>AI usage</b> · "), first)
        XCTAssertTrue(first.contains(" · ◀ Cress's Mac\n"), "whose Mac the ◀ marks: \(first)")
        let keyboard = api.sent().first?["reply_markup"] as? [String: Any]
        XCTAssertEqual(keyboard?["is_persistent"] as? Bool, true, "their own Usage button")
        XCTAssertEqual(texts(api, to: 222), [], "nothing for the owner to answer")
        XCTAssertEqual(UsageMenu.sharingLines(app.usageMenuState()), ["Shared with Lim Wei"])
        XCTAssertEqual(TelegramViewers.standard().status(of: 555), .allowed, "kept for the next start")

        clockNow += 10
        api.push(message(51, "📊 Usage", chat: 555, name: "Lim Wei"))
        try await until("a second report") { bot.answered == 2 }
        let second = try XCTUnwrap(texts(api, to: 555).dropFirst().first)
        XCTAssertTrue(second.hasPrefix("📊 <b>AI usage</b> · "), "the word on the button comes once: \(second)")
    }

    func testStopSharingCutsSomeoneOffAndShareAgainUndoesIt() async throws {
        let api = FakeBotAPI()
        let (app, bot) = try await listeningApp(api)
        defer { bot.stop(); withExtendedLifetime(app) {} }
        api.push(message(60, "/usage", chat: 555, name: "Lim Wei"))
        try await until("their report") { bot.answered == 1 }

        app.stopSharing(with: 555, confirm: { _ in false })
        XCTAssertEqual(app.telegramViewers.status(of: 555), .allowed, "Cancel changes nothing")
        app.stopSharing(with: 555, confirm: { _ in true })
        XCTAssertEqual(app.telegramViewers.status(of: 555), .blocked)
        try await until("they are told") { texts(api, to: 555).count == 2 }
        XCTAssertEqual(texts(api, to: 555).last, "🔒 Cress stopped sharing AI usage with you.")
        XCTAssertEqual(api.sent().last?["reply_markup"] as? [String: Bool], ["remove_keyboard": true], "their button goes")
        XCTAssertEqual(UsageMenu.sharingLines(app.usageMenuState()), [])

        clockNow += 60
        api.push(message(61, "/usage", chat: 555, name: "Lim Wei"), message(62, "📊 Usage"))
        try await until("the owner's report") { bot.answered == 2 }
        XCTAssertEqual(texts(api, to: 555).count, 2, "no answer once sharing stopped")

        app.shareAgain(with: 555)
        try await until("they are told") { texts(api, to: 555).count == 3 }
        XCTAssertEqual(texts(api, to: 555).last, "🔓 Cress is sharing AI usage with you again. Tap <b>📊 Usage</b> below any time.")
        XCTAssertEqual((api.sent().last?["reply_markup"] as? [String: Any])?["is_persistent"] as? Bool, true, "their button is back")
        XCTAssertEqual(UsageMenu.sharingLines(app.usageMenuState()), ["Shared with Lim Wei"])
        clockNow += 60
        api.push(message(63, "/usage", chat: 555, name: "Lim Wei"))
        try await until("a report again") { bot.answered == 3 }
        XCTAssertTrue(texts(api, to: 555).last?.hasPrefix("📊 <b>AI usage</b> · ") ?? false, texts(api, to: 555).last ?? "none")
    }

    func testTwoPeopleTappingTogetherBothGetAReport() async throws {
        let api = FakeBotAPI()
        let (app, bot) = try await listeningApp(api)
        defer { bot.stop(); withExtendedLifetime(app) {} }
        api.push(message(80, "📊 Usage"), message(81, "📊 Usage", chat: 555, name: "Lim Wei"))
        try await until("two reports") { bot.answered == 2 }
        XCTAssertTrue(texts(api, to: 555).last?.contains(" · ◀ Cress's Mac\n") ?? false, texts(api, to: 555).last ?? "none")
        XCTAssertFalse(texts(api, to: 222).last?.contains("'s Mac") ?? true, "the owner's own report needs no note")
    }

    func testTheButtonUnderAnAlertIsAnsweredAndADoubleTapSendsOneReport() async throws {
        let api = FakeBotAPI()
        let (app, bot) = try await listeningApp(api)
        defer { bot.stop(); withExtendedLifetime(app) {} }
        api.push(tap(5), tap(6))
        try await until("both taps answered") { api.calls.filter { $0.method == "answerCallbackQuery" }.count == 2 }
        try await until("a report") { bot.answered == 1 }
        let answers = api.calls.filter { $0.method == "answerCallbackQuery" }.map { $0.body["text"] as? String }
        XCTAssertEqual(answers, ["Checking usage…", "Just sent"])
        XCTAssertEqual(api.sent().count, 1, "a second tap within 3 s sends nothing more")
        XCTAssertEqual(bot.answered, 1)
    }

    func testARevokedTokenStopsListeningAndTheMenuSaysWhy() async throws {
        let api = FakeBotAPI()
        api.getUpdatesStatus = 401
        try connectTelegram()
        let app = makeApp()
        let bot = TelegramBot(transport: api.transport(), clock: { [unowned self] in clockNow })
        app.telegramBot = bot
        app.syncTelegramBot()
        try await until("the bot to give up") { !bot.isListening }
        XCTAssertEqual(api.calls.filter { $0.method == "getUpdates" }.count, 1, "no retrying a revoked token")
        XCTAssertTrue(app.usageMenuState().telegramProblem?.contains("@BotFather") ?? false,
                      app.usageMenuState().telegramProblem ?? "no problem shown")
    }

    func testADroppedLongPollIsRiddenOutQuietly() async throws {
        let api = FakeBotAPI()
        api.dropsLeft = 3 // a Wi-Fi blip: three long polls lose their connection
        try connectTelegram()
        let app = makeApp()
        let bot = TelegramBot(transport: api.transport(), clock: { [unowned self] in clockNow })
        bot.pauseAfter = { _, _ in 0.01 }
        app.telegramBot = bot
        app.syncTelegramBot()
        defer { bot.stop() }
        var said: [String?] = []
        let tellApp = bot.onProblem
        bot.onProblem = { problem in
            said.append(problem)
            tellApp(problem)
        }
        try await until("listening again") {
            api.calls.filter { $0.method == "getUpdates" && ($0.body["offset"] as? NSNumber)?.intValue != -1 }.count >= 5
        }
        XCTAssertEqual(said.compactMap { $0 }, [], "three drops in a row are routine: never shown")
        XCTAssertNil(app.usageMenuState().telegramProblem)
        XCTAssertTrue(bot.isListening)
    }

    func testTheBotStepsAsideWhileSetupReadsTheChat() async throws {
        let api = FakeBotAPI()
        try connectTelegram()
        let app = makeApp()
        app.telegramBot = TelegramBot(transport: api.transport(), clock: { [unowned self] in clockNow })
        var release: CheckedContinuation<Void, Never>?
        XCTAssertTrue(TelegramSetup.run({ await withCheckedContinuation { release = $0 }; return nil }, completion: { _ in }))
        app.syncTelegramBot()
        XCTAssertFalse(app.telegramBot.isListening, "Telegram allows one reader: the setup")
        while release == nil { await Task.yield() }
        release?.resume()
        while TelegramSetup.isRunning { await Task.yield() }
        app.syncTelegramBot()
        XCTAssertTrue(app.telegramBot.isListening)
        app.telegramBot.stop()
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
        let snapshot = UsageSnapshot.parse(dashboardJSON(trimoWeekly: 94), fetchedAt: now)
        state.status = UsageMonitor.Status(snapshot: snapshot, signedIn: ["trimo@example.com"])
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — trimo at 94% weekly · 28% session",
                       "the account in use, with its limits")
        XCTAssertEqual(UsageMenu.followed(state), "Alerts for trimo (in use)")
        XCTAssertEqual(UsageMenu.topSymbol(state).name, "exclamationmark.triangle.fill")
        XCTAssertEqual(UsageMenu.sorted(snapshot!.accounts, followed: ["claude|trimo"]).map(\.label),
                       ["trimo", "CoreOS", "cresswell-nexxatech"], "followed first, then fullest first")
        XCTAssertEqual(UsageMenu.freshness(state, now: now), "Updated just now")

        state.status.signedIn = ["cresswell-nexxatech@example.com"]
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — cresswell-nexxatech at 65% session · 44% weekly")
        XCTAssertEqual(UsageMenu.topSymbol(state).name, "gauge.with.dots.needle.33percent",
                       "CoreOS at 100% is not the account in use: no warning on top")
        state.status.signedIn = ["someone@example.com"]
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — someone@example.com is not on the dashboard")
        let signedIn = state.status.signedIn
        state.status.scope = UsageAlertScope(["codex:typo"])
        state.status.signedIn = ["trimo@example.com"]
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — usageAlertAccounts names no account on the dashboard",
                       "the setting is the problem, not the sign-in")
        XCTAssertEqual(UsageMenu.followed(state), "Alerts for nobody: usageAlertAccounts names no account on the dashboard")
        state.status.scope = UsageAlertScope(["current"])
        state.status.signedIn = signedIn
        state.status.signedIn = nil
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — can't tell which account is in use")
        XCTAssertEqual(UsageMenu.followed(state), "Alerts wait: no Claude sign-in found")
        state.status.scope = UsageAlertScope(["all"])
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — 2 at 90%+")
        XCTAssertEqual(UsageMenu.followed(state), "Alerts for every account")
        state.enabled = false
        XCTAssertEqual(UsageMenu.title(state, now: now), "Usage limits — alerts off")
        for name in ["gauge.with.dots.needle.33percent", "exclamationmark.triangle.fill", "questionmark.circle"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) must exist")
        }
    }
}
