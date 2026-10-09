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
    private let token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("usage-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        setenv("AI_SESSIONS_HOME", home.path, 1)
        sent = []
    }

    override func tearDown() {
        Log.shared.flush()
        if let savedHome { setenv("AI_SESSIONS_HOME", savedHome, 1) } else { unsetenv("AI_SESSIONS_HOME") }
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    // MARK: Fixtures

    /// Mutable answer for the fake dashboard.
    private final class Dashboard: @unchecked Sendable {
        var body: Data?
        var calls = 0
    }

    private func dashboardJSON(trimoWeekly: Double, trimoSession: Double = 28) -> Data {
        func row(_ label: String, session: Double, weekly: Double) -> [String: Any] {
            ["tool": "claude", "label": label, "skipped": false, "limits": ["error": NSNull(), "windows": [
                ["kind": "session", "label": "Session (5hr)", "pct": session, "resets": 1_791_610_000],
                ["kind": "weekly_all", "label": "Weekly (7 day)", "pct": weekly, "resets": 1_791_800_000],
            ]] as [String: Any]]
        }
        // CoreOS is maxed out from before, like six accounts on the real
        // dashboard: the first reading must record it, not announce it.
        return try! JSONSerialization.data(withJSONObject: ["rows": [
            row("trimo", session: trimoSession, weekly: trimoWeekly),
            row("cresswell-nexxatech", session: 65, weekly: 44),
            row("CoreOS", session: 0, weekly: 100),
        ]])
    }

    private func makeApp() -> AppDelegate {
        let store = StateStore(url: home.appendingPathComponent("state/state.json"))
        let app = AppDelegate { config in SessionEngine(config: config, store: store, makeSources: { _ in [] }) }
        center = RecordingCenter()
        app.install(Notifier(center: center))
        app.sendTelegram = { [unowned self] settings, html in self.sent.append((settings, html)) }
        return app
    }

    private func monitor(for app: AppDelegate, _ dashboard: Dashboard) -> UsageMonitor {
        UsageMonitor(config: app.config,
                     engine: UsageAlertEngine(url: home.appendingPathComponent("state/usage-alerts.json"), threshold: 90),
                     fetch: { _ in
                         dashboard.calls += 1
                         guard let body = dashboard.body else { throw URLError(.cannotConnectToHost) }
                         return body
                     })
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
        XCTAssertEqual(center.posted.count, 1)
        XCTAssertTrue(sent.isEmpty, "nothing to send to before a bot is connected")
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
        XCTAssertEqual(UsageMenu.title(state, now: Date()), "Usage limits — 1 at 90%+ (last known)")
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

    func testUsageMenuTitles() {
        let now = Date()
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
