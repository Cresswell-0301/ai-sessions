import XCTest
@testable import AISessionsCore

/// The usage-limit alert: parsing the dashboard, deciding what is news, and
/// the words. Fixtures follow the dashboard's real /data.json (2026-10-10).
final class UsageTests: XCTestCase {
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_791_600_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private func window(_ kind: String, _ pct: Double?, resets: Double? = nil, label: String? = nil) -> [String: Any] {
        var w: [String: Any] = ["kind": kind, "label": label ?? kind, "severity": "normal", "active": true, "live": true]
        w["pct"] = pct ?? NSNull()
        w["resets"] = resets ?? NSNull()
        return w
    }

    private func row(_ tool: String, _ label: String, _ windows: [[String: Any]], error: String? = nil,
                     skipped: Bool = false) -> [String: Any] {
        var limits: [String: Any] = ["windows": windows, "live": true, "plan": "max"]
        limits["error"] = error ?? NSNull()
        return ["tool": tool, "label": label, "email": "\(label)@example.com", "skipped": skipped, "limits": limits]
    }

    private func data(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["rows": rows, "meta": ["generated": 1, "interval": 10]])
    }

    /// One Claude account with session, weekly and Fable windows.
    private func claude(_ label: String, session: Double, weekly: Double, weeklyResets: Double = 1_791_800_000) -> [String: Any] {
        row("claude", label, [
            window("session", session, resets: session > 0 ? 1_791_610_000 : nil, label: "Session (5hr)"),
            window("weekly_all", weekly, resets: weeklyResets, label: "Weekly (7 day)"),
            window("weekly_scoped", 0, resets: weeklyResets, label: "Weekly Fable"),
        ])
    }

    private func snapshot(_ rows: [[String: Any]], at date: Date? = nil) -> UsageSnapshot {
        UsageSnapshot.parse(data(rows), fetchedAt: date ?? now)!
    }

    private func engine(threshold: Double = 90) -> UsageAlertEngine {
        UsageAlertEngine(url: dir.appendingPathComponent("usage-alerts.json"), threshold: threshold, now: { [now] in now })
    }

    private func keys(_ alerts: [UsageAlert]) -> [String] { alerts.map(\.key) }

    // MARK: Parsing

    func testParsesTheDashboardsRows() throws {
        let parsed = snapshot([
            claude("trimo", session: 28, weekly: 94),
            row("codex", "nexxaflo", [window("weekly", 27, resets: 1_791_900_000, label: "Weekly")]),
            row("claude", "excluded", [window("weekly_all", 99)], skipped: true),
            row("claude", "signed-out", [], error: "token expired — re-login"),
            row("claude", "half", [window("weekly_all", nil), window("session", 12)]),
        ])
        XCTAssertEqual(parsed.accounts.map(\.label), ["trimo", "nexxaflo", "signed-out", "half"], "skipped rows are left out")
        let trimo = parsed.accounts[0]
        XCTAssertEqual(trimo.windows.map(\.kind), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(trimo.windows[1].pct, 94)
        XCTAssertEqual(trimo.windows[1].resetsAt, Date(timeIntervalSince1970: 1_791_800_000))
        XCTAssertEqual(trimo.windows[0].resetsAt, Date(timeIntervalSince1970: 1_791_610_000), "a session in use resets")
        XCTAssertTrue(trimo.readable)
        XCTAssertEqual(parsed.accounts[1].tool, "codex")
        XCTAssertFalse(parsed.accounts[2].readable, "an account the dashboard could not read")
        XCTAssertEqual(parsed.accounts[3].windows.map(\.kind), ["session"], "a window without a number is left out")
        XCTAssertNil(UsageSnapshot.parse(Data("[1,2]".utf8), fetchedAt: now))
        XCTAssertNil(UsageSnapshot.parse(Data("not json".utf8), fetchedAt: now))
    }

    // MARK: What is news

    func testTheFirstReadingOnlyRecordsWhatIsAlreadyOver() {
        let engine = engine()
        XCTAssertTrue(engine.isFirstRun)
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 28, weekly: 94),
                                                 claude("CoreOS", session: 0, weekly: 100)])), [],
                       "accounts maxed out days ago are not news")
        XCTAssertFalse(engine.isFirstRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.url.path))
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 28, weekly: 96)])), [],
                       "and they stay quiet while still over")
    }

    func testACrossingAlertsOnceThenStaysQuietWhileOver() {
        let engine = engine()
        _ = engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 85)]))
        XCTAssertEqual(keys(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 91)]))),
                       ["claude|trimo|weekly_all"])
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 97)])), [], "once per crossing")
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 100)])), [])
    }

    func testSessionAndWeeklyAreSeparateWindows() {
        let engine = engine()
        _ = engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 50)]))
        let alerts = engine.evaluate(snapshot([claude("trimo", session: 92, weekly: 93)]))
        XCTAssertEqual(keys(alerts), ["claude|trimo|session", "claude|trimo|weekly_all"])
    }

    func testDroppingBelowArmsItAgain() {
        let engine = engine()
        _ = engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 80)]))
        XCTAssertEqual(keys(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 90)]))), ["claude|trimo|weekly_all"])
        // The week resets: usage falls, then climbs again in the new week.
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 3, weeklyResets: 1_792_400_000)])), [])
        XCTAssertEqual(keys(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 92, weeklyResets: 1_792_400_000)]))),
                       ["claude|trimo|weekly_all"])
    }

    func testANewPeriodThatIsAlreadyOverAlertsAgain() {
        let engine = engine()
        _ = engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 80)]))
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 95)])).count, 1)
        // Missed the dip (app off over the reset): a different period, still over.
        XCTAssertEqual(keys(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 95, weeklyResets: 1_792_404_800)]))),
                       ["claude|trimo|weekly_all"])
    }

    func testAResetTimeThatWobblesIsTheSamePeriod() {
        let engine = engine()
        _ = engine.evaluate(snapshot([row("codex", "nexxaflo", [window("weekly", 50, resets: 1_791_900_000)])]))
        XCTAssertEqual(engine.evaluate(snapshot([row("codex", "nexxaflo", [window("weekly", 91, resets: 1_791_900_000)])])).count, 1)
        // Codex derives the reset from "resets in N s": a few minutes of drift.
        XCTAssertEqual(engine.evaluate(snapshot([row("codex", "nexxaflo", [window("weekly", 93, resets: 1_791_900_420)])])), [],
                       "7 minutes of drift is the same week")
    }

    func testARestartDoesNotRepeatAnAlert() {
        let first = engine()
        _ = first.evaluate(snapshot([claude("trimo", session: 20, weekly: 80)]))
        XCTAssertEqual(first.evaluate(snapshot([claude("trimo", session: 20, weekly: 91)])).count, 1)
        let restarted = engine()
        XCTAssertFalse(restarted.isFirstRun)
        XCTAssertEqual(restarted.evaluate(snapshot([claude("trimo", session: 20, weekly: 92)])), [])
    }

    func testAnUnreadableAccountNeitherAlertsNorRearms() {
        let engine = engine()
        _ = engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 80)]))
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 95)])).count, 1)
        XCTAssertEqual(engine.evaluate(snapshot([row("claude", "trimo", [], error: "rate limited")])), [])
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 96)])), [],
                       "a read failure is not a drop below the threshold")
    }

    func testAnAccountTheDashboardDropsIsForgotten() {
        let engine = engine()
        _ = engine.evaluate(snapshot([claude("trimo", session: 20, weekly: 95), claude("other", session: 1, weekly: 1)]))
        XCTAssertNotNil(engine.state.alerted["claude|trimo|weekly_all"])
        _ = engine.evaluate(snapshot([claude("other", session: 1, weekly: 1)]))
        XCTAssertNil(engine.state.alerted["claude|trimo|weekly_all"])
    }

    func testRoundingFollowsTheDashboard() {
        let engine = engine()
        _ = engine.evaluate(snapshot([claude("a", session: 0, weekly: 10), claude("b", session: 0, weekly: 10)]))
        let alerts = engine.evaluate(snapshot([claude("a", session: 0, weekly: 89.5), claude("b", session: 0, weekly: 89.4)]))
        XCTAssertEqual(keys(alerts), ["claude|a|weekly_all"], "the dashboard shows 89.5 as 90%")
    }

    func testTheThresholdIsConfigurable() {
        let engine = engine(threshold: 75)
        _ = engine.evaluate(snapshot([claude("trimo", session: 0, weekly: 70)]))
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 0, weekly: 76)])).count, 1)
    }

    // MARK: Most room

    func testMostRoomIsTheLowestWeeklyAmongAccountsUnderTheThreshold() {
        let snap = snapshot([claude("full", session: 0, weekly: 100), claude("busy", session: 65, weekly: 44),
                             claude("fresh", session: 0, weekly: 53), claude("hot", session: 95, weekly: 5)])
        XCTAssertEqual(snap.mostRoom(threshold: 90)?.label, "busy", "lowest weekly; 'hot' has a window over 90%")
        XCTAssertNil(snapshot([claude("full", session: 0, weekly: 100)]).mostRoom(threshold: 90))
    }

    // MARK: Words

    func testTheBannerForOneCrossing() {
        let snap = snapshot([claude("trimo", session: 28, weekly: 94, weeklyResets: now.timeIntervalSince1970 + 2 * 86_400 + 4 * 3_600 + 60),
                             claude("cresswell", session: 65, weekly: 44)])
        let alert = UsageAlert(account: snap.accounts[0], window: snap.accounts[0].windows[1])
        let text = UsageText.notification(for: [alert], snapshot: snap, threshold: 90)
        XCTAssertEqual(text.title, "trimo: Claude weekly limit at 94%")
        XCTAssertEqual(text.subtitle, "resets in 2d 4h")
        XCTAssertEqual(text.body, "Most room now: cresswell (56% of the week left).")
    }

    func testTheBannerForSeveralCrossings() {
        let snap = snapshot([claude("a", session: 91, weekly: 92), claude("b", session: 100, weekly: 100)])
        let alerts = [UsageAlert(account: snap.accounts[0], window: snap.accounts[0].windows[0]),
                      UsageAlert(account: snap.accounts[0], window: snap.accounts[0].windows[1])]
        let text = UsageText.notification(for: alerts, snapshot: snap, threshold: 90)
        XCTAssertEqual(text.title, "2 limits passed 90%")
        XCTAssertEqual(text.subtitle, "a · Claude session 91%, a · Claude weekly 92%")
        XCTAssertEqual(text.body, "No Claude account is under 90% right now.")
    }

    func testTheTelegramMessageNamesTheCrossingAndEveryAccount() {
        let snap = snapshot([claude("tr<i>mo", session: 28, weekly: 94), claude("cresswell", session: 65, weekly: 44),
                             row("codex", "nexxaflo", [window("weekly", 27)])])
        let alert = UsageAlert(account: snap.accounts[0], window: snap.accounts[0].windows[1])
        let html = UsageText.telegram(for: [alert], snapshot: snap, threshold: 90)
        XCTAssertTrue(html.hasPrefix("⚠️ <b>AI usage — limit almost hit</b>\n• <b>tr&lt;i&gt;mo</b> — Claude weekly at <b>94%</b>"), html)
        XCTAssertFalse(html.contains("<i>mo"), "labels are escaped, not markup")
        XCTAssertTrue(html.contains("<b>Claude Code</b>\n<pre>account"), html)
        XCTAssertTrue(html.contains("cresswell       65%   44%   0%"), html)
        XCTAssertTrue(html.contains("tr&lt;i&gt;mo         28%   94%   0% ⚠"), html)
        XCTAssertTrue(html.contains("<b>Codex</b>\n<pre>nexxaflo        27%</pre>"), html)
        XCTAssertTrue(html.hasSuffix("➡️ Most room now: <b>cresswell</b>"), html)
    }

    func testDurationsAndMenuRows() {
        XCTAssertEqual(UsageText.until(now.addingTimeInterval(2 * 86_400 + 4 * 3_600 + 59), now: now), "2d 4h")
        XCTAssertEqual(UsageText.until(now.addingTimeInterval(3 * 3_600 + 10 * 60), now: now), "3h 10m")
        XCTAssertEqual(UsageText.until(now.addingTimeInterval(20), now: now), "1m")
        XCTAssertNil(UsageText.until(nil, now: now))
        let snap = snapshot([claude("trimo", session: 28, weekly: 94), row("claude", "dead", [], error: "x")])
        XCTAssertEqual(UsageText.menuRow(snap.accounts[0]), "trimo — weekly 94% · session 28%", "unused Fable window hidden")
        XCTAssertEqual(UsageText.menuRow(snap.accounts[1]), "dead — not readable")
        XCTAssertEqual(UsageText.html("a&b<c>"), "a&amp;b&lt;c&gt;")
    }
}
