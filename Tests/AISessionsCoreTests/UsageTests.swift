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

    /// `skipped` as the real dashboard sends it on every Claude row: a note
    /// on its token-cost scan, not on the limits.
    private func row(_ tool: String, _ label: String, _ windows: [[String: Any]], error: String? = nil,
                     skipped: Any = "signed in — no usage recorded yet", age: Double = 60) -> [String: Any] {
        var limits: [String: Any] = ["windows": windows, "live": true, "plan": "max",
                                     "as_of": now.timeIntervalSince1970 - age]
        limits["error"] = error ?? NSNull()
        return ["tool": tool, "label": label, "email": "\(label)@example.com", "skipped": skipped, "limits": limits]
    }

    private func data(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["rows": rows, "meta": ["generated": 1, "interval": 10]])
    }

    /// One Claude account with session, weekly and Fable windows.
    private func claude(_ label: String, session: Double, weekly: Double, weeklyResets: Double = 1_791_800_000,
                        age: Double = 60) -> [String: Any] {
        row("claude", label, [
            window("session", session, resets: session > 0 ? 1_791_610_000 : nil, label: "Session (5hr)"),
            window("weekly_all", weekly, resets: weeklyResets, label: "Weekly (7 day)"),
            window("weekly_scoped", 0, resets: weeklyResets, label: "Weekly Fable"),
        ], age: age)
    }

    private func snapshot(_ rows: [[String: Any]], at date: Date? = nil) -> UsageSnapshot {
        UsageSnapshot.parse(data(rows), fetchedAt: date ?? now)!
    }

    private func snapshot(_ rows: [[String: Any]], at seconds: Double) -> UsageSnapshot {
        snapshot(rows, at: Date(timeIntervalSince1970: seconds))
    }

    /// A Codex row as the dashboard writes it: no `skipped`, no limits.error.
    private func codex(_ windows: [[String: Any]]) -> [String: Any] { codex("acct", windows) }

    private func codex(_ label: String, _ windows: [[String: Any]]) -> [String: Any] {
        ["tool": "codex", "label": label, "email": "\(label)@example.com",
         "limits": ["windows": windows, "plan": "plus", "as_of": now.timeIntervalSince1970 - 600] as [String: Any]]
    }

    /// A Codex window; `inferred` is the dashboard's note on a number it did not read now.
    private func cwindow(_ kind: String, _ pct: Double, resets: Double?, inferred: String? = nil) -> [String: Any] {
        ["kind": kind, "label": kind == "usage" ? "Usage" : "Weekly (7 day)", "pct": pct,
         "resets": resets ?? NSNull(), "inferred": inferred ?? NSNull(), "active": kind == "usage"]
    }

    private func engine(threshold: Double = 90) -> UsageAlertEngine {
        UsageAlertEngine(url: dir.appendingPathComponent("usage-alerts.json"), threshold: threshold, now: { [now] in now })
    }

    private func keys(_ alerts: [UsageAlert]) -> [String] { alerts.map(\.key) }

    /// Account `index` of `snap`: a failed test, not a crash, when parsing lost it.
    private func account(_ snap: UsageSnapshot, _ index: Int) throws -> UsageAccount {
        try XCTUnwrap(snap.accounts.indices.contains(index) ? snap.accounts[index] : nil,
                      "parsed \(snap.accounts.map(\.label))")
    }

    private func crossing(_ snap: UsageSnapshot, _ index: Int, _ kind: String) throws -> UsageAlert {
        let account = try account(snap, index)
        return UsageAlert(account: account, window: try XCTUnwrap(account.windows.first { $0.kind == kind }))
    }

    // MARK: Parsing

    func testParsesTheDashboardsRows() throws {
        let parsed = snapshot([
            claude("trimo", session: 28, weekly: 94),
            row("codex", "nexxaflo", [window("weekly", 27, resets: 1_791_900_000, label: "Weekly")]),
            row("claude", "excluded", [window("weekly_all", 99)], skipped: "excluded account (excluded@example.com)"),
            row("claude", "signed-out", [], error: "token expired — re-login"),
            row("claude", "half", [window("weekly_all", nil), window("session", 12)]),
        ])
        XCTAssertEqual(parsed.accounts.map(\.label), ["trimo", "nexxaflo", "signed-out", "half"], "excluded rows are left out")
        guard parsed.accounts.count == 4 else { return }
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

    func testSkippedIsTheCostScansNoteNotAnExclusion() {
        let parsed = snapshot([
            claude("trimo", session: 28, weekly: 94),
            row("claude", "plain", [window("weekly_all", 50)], skipped: false),
            row("claude", "none", [window("weekly_all", 51)], skipped: NSNull()),
            row("claude", "gone", [window("weekly_all", 99)], skipped: "excluded account (gone@example.com)"),
            row("claude", "flagged", [window("weekly_all", 99)], skipped: true),
        ])
        XCTAssertEqual(parsed.accounts.map(\.label), ["trimo", "plain", "none"],
                       "a note keeps the row; only an exclusion (or plain true) drops it")
        XCTAssertEqual(parsed.accounts.first?.readable, true)
    }

    func testAWildPercentIsBoundedNotATrap() throws {
        let wild = try XCTUnwrap(snapshot([row("claude", "wild", [window("session", 1e300), window("weekly_all", -4)])]).accounts.first)
        XCTAssertEqual(wild.windows.map(\.pct), [1000, 0])
        XCTAssertEqual(UsageText.menuRow(wild), "wild — session 1000% · weekly 0%")
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

    // Readings that are not news. Shapes and numbers are the dashboard's own
    // output on real Codex histories (review of 2026-10-10).

    func testAnOldCodexReadingAfterItsResetIsNotNews() {
        let R = 1_791_600_000.0
        let engine = engine()
        _ = engine.evaluate(snapshot([codex([cwindow("weekly", 85, resets: R)])], at: R - 5 * 3600))
        XCTAssertEqual(keys(engine.evaluate(snapshot([codex([cwindow("weekly", 95, resets: R)])], at: R - 2 * 3600))),
                       ["codex|acct|weekly"])
        // The week reset and nothing ran since: the dashboard infers 0%.
        XCTAssertEqual(engine.evaluate(snapshot([codex([cwindow("weekly", 0, resets: R,
                                                                inferred: "window reset, no activity since")])], at: R + 600)), [])
        // A run started but has not written a reading yet: the old 95% is back.
        XCTAssertEqual(engine.evaluate(snapshot([codex([cwindow("weekly", 95, resets: R,
                                                                inferred: "stale — account ran after this reading")])], at: R + 1260)), [],
                       "the week that ended at R was announced already")
        XCTAssertEqual(keys(engine.evaluate(snapshot([codex([cwindow("weekly", 91, resets: R + 7 * 86_400)])], at: R + 3 * 86_400))),
                       ["codex|acct|weekly"], "the new week crossing is news")
    }

    func testACodexRefusalThatLosesItsDateIsTheSameWeek() {
        let R = 1_789_814_580.0
        let engine = engine()
        _ = engine.evaluate(snapshot([codex([cwindow("weekly", 80, resets: R)])], at: R - 5 * 86_400))
        XCTAssertEqual(keys(engine.evaluate(snapshot([codex([cwindow("usage", 100, resets: R)])], at: R - 4 * 86_400))),
                       ["codex|acct|usage"], "refused: announced once")
        // On the reset's own day Codex says "try again at 6:33 PM": no date.
        XCTAssertEqual(engine.evaluate(snapshot([codex([cwindow("usage", 100, resets: nil)])], at: R - 18 * 3600)), [],
                       "the same exhausted week")
        // The new week: a run succeeds and the refusal is gone…
        XCTAssertEqual(engine.evaluate(snapshot([codex([cwindow("weekly", 1, resets: R + 7 * 86_400)])], at: R + 3660)), [])
        // …until it is exhausted again, first seen on that reset's own day.
        XCTAssertEqual(keys(engine.evaluate(snapshot([codex([cwindow("usage", 100, resets: nil)])], at: R + 7 * 86_400 - 6 * 3600))),
                       ["codex|acct|usage"], "a new week, refused again: news")
    }

    func testARefusalWithoutAResetIsArmedAgainOnceItIsGone() {
        let R = 1_789_814_580.0
        let engine = engine()
        _ = engine.evaluate(snapshot([codex([cwindow("weekly", 50, resets: R)])], at: R - 2 * 86_400))
        XCTAssertEqual(keys(engine.evaluate(snapshot([codex([cwindow("usage", 100, resets: nil)])], at: R - 3600))),
                       ["codex|acct|usage"])
        _ = engine.evaluate(snapshot([codex([cwindow("weekly", 2, resets: R + 7 * 86_400)])], at: R + 3600))
        XCTAssertNil(engine.state.alerted["codex|acct|usage"], "the refusal went away")
        XCTAssertEqual(keys(engine.evaluate(snapshot([codex([cwindow("usage", 100, resets: nil)])], at: R + 6 * 86_400))),
                       ["codex|acct|usage"], "refused again later: news")
    }

    func testAnotherLimitAtZeroIsNotADropOfThisWindow() {
        // trimomalaysia, 2026-09-25: a run ended on another Codex limit, so for
        // one probe the dashboard showed weekly 0% with that limit's reset.
        let R = 1_790_421_300.0, t = R - 12 * 3600
        let engine = engine(threshold: 80)
        _ = engine.evaluate(snapshot([codex("trimomalaysia", [cwindow("weekly", 79, resets: R)])], at: t - 3600))
        XCTAssertEqual(keys(engine.evaluate(snapshot([codex("trimomalaysia", [cwindow("weekly", 85, resets: R)])], at: t))),
                       ["codex|trimomalaysia|weekly"])
        XCTAssertEqual(engine.evaluate(snapshot([codex("trimomalaysia", [cwindow("weekly", 0, resets: 1_790_984_868)])], at: t + 900)), [])
        XCTAssertEqual(engine.evaluate(snapshot([codex("trimomalaysia", [cwindow("weekly", 85, resets: R)])], at: t + 4500)), [],
                       "the same week as the crossing")
    }

    func testADropWithinTheSameWeekArmsItAgain() {
        let engine = engine()
        _ = engine.evaluate(snapshot([claude("trimo", session: 0, weekly: 80)]))
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 0, weekly: 95)])).count, 1)
        XCTAssertEqual(engine.evaluate(snapshot([claude("trimo", session: 0, weekly: 85)])), [])
        XCTAssertEqual(keys(engine.evaluate(snapshot([claude("trimo", session: 0, weekly: 93)]))), ["claude|trimo|weekly_all"],
                       "below, then over again, in one week: a second crossing")
    }

    func testEachScopedWeeklyLimitIsItsOwnWindow() {
        let W = 1_791_975_600.0
        func trimo(opus: Double) -> [String: Any] {
            row("claude", "trimo", [window("session", 10, label: "Session (5hr)"),
                                   window("weekly_all", 60, resets: W, label: "Weekly (7 day)"),
                                   window("weekly_scoped", opus, resets: W, label: "Weekly Opus"),
                                   window("weekly_scoped", 0, resets: W, label: "Weekly Fable")])
        }
        let engine = engine()
        _ = engine.evaluate(snapshot([trimo(opus: 50)]))
        XCTAssertEqual(keys(engine.evaluate(snapshot([trimo(opus: 96)]))), ["claude|trimo|weekly_scoped:Weekly Opus"])
        let polls = (0..<5).map { _ in engine.evaluate(snapshot([trimo(opus: 96)])).count }
        XCTAssertEqual(polls, [0, 0, 0, 0, 0], "an unchanged reading is not news, poll after poll")
        // Two windows that share a key even so: the fuller one speaks for both.
        let twins = row("claude", "x", [window("weekly_scoped", 96, resets: W, label: "Weekly"),
                                        window("weekly_scoped", 0, resets: W, label: "Weekly")])
        _ = engine.evaluate(snapshot([twins]))
        XCTAssertEqual((0..<3).map { _ in engine.evaluate(snapshot([twins])).count }, [0, 0, 0])
    }

    func testTheFirstReadingAlsoRecordsAccountsItCouldNotRead() {
        let engine = engine()
        let limited = row("claude", "maxed", [window("weekly_all", 100, resets: 1_791_800_000)], error: "Rate Limit")
        XCTAssertEqual(engine.evaluate(snapshot([limited])), [])
        XCTAssertEqual(engine.evaluate(snapshot([claude("maxed", session: 0, weekly: 100)])), [],
                       "at its cap before the app's first reading (behind a 429): not news")
    }

    func testAnEndedOrStaleWindowDoesNotCountAsOver() {
        let R = 1_791_600_000.0
        let snap = snapshot([codex("ended", [cwindow("weekly", 95, resets: R - 60)]),
                             codex("stale", [cwindow("weekly", 95, resets: R + 86_400, inferred: "stale — account ran after this reading")]),
                             codex("live", [cwindow("weekly", 95, resets: R + 86_400)])], at: R)
        XCTAssertEqual(snap.over(90).map(\.label), ["live"])

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

    // MARK: Words

    private let utc = TimeZone(identifier: "UTC")!

    /// The words' inputs, the accounts named in `inUse` signed in on this Mac.
    private func view(_ snap: UsageSnapshot, inUse: [String] = [], excluded: Set<String> = []) -> UsageView {
        let followed = snap.accounts.filter { inUse.contains($0.label) }
        return UsageView(snapshot: snap, threshold: 90, followed: followed, inUse: Set(followed.map(\.key)),
                         excluded: excluded, timeZone: utc)
    }

    private func lines(_ html: String) -> [String] { html.components(separatedBy: "\n") }

    func testTheReportShowsTheAccountInUseItsRenewalsAndTheAdvice() {
        // now = Sat 10 Oct 02:40 UTC; sessions renew 05:26, weeks Mon 10:13.
        let snap = snapshot([claude("cress", session: 69, weekly: 72), claude("full", session: 0, weekly: 100),
                             claude("roomy", session: 0, weekly: 53, weeklyResets: now.timeIntervalSince1970 + 6 * 86_400),
                             row("codex", "cx", [window("weekly", 37, resets: now.timeIntervalSince1970 + 3 * 86_400)])])
        XCTAssertEqual(lines(UsageText.reportMessage(view(snap, inUse: ["cress"]))), [
            "📊 <b>AI usage</b> · 02:40",
            "<b>cress</b> · Claude · in use on this Mac",
            "• Session 69% · renews in 2h 46m (05:26)",
            "• Weekly 72% · renews in 2d 7h (Mon 10:13)",
            "",
            "👉 Use first: <b>cress</b> · 28% left · renews in 2d — the one you're on",
            "    then <b>roomy</b> · 47% left · renews in 6d",
            "📈 Most usage left: <b>roomy</b> · 47% left",
            "",
            "<b>Claude Code</b>",
            "<pre>account       session    week",
            "cress         69% 2h46m  72% 2d7h ◀",
            "full          0%         100% 2d7h ⚠",
            "roomy         0%         53% 6d</pre>",
            "<b>Codex</b>",
            "<pre>cx            37% 3d</pre>",
        ])
    }

    func testTheAlertNamesTheCrossingWithRenewalsAndWhereToGo() throws {
        let snap = snapshot([claude("tr<i>mo", session: 28, weekly: 94),
                             claude("roomy", session: 0, weekly: 53, weeklyResets: now.timeIntervalSince1970 + 6 * 86_400)])
        let html = UsageText.alertMessage([try crossing(snap, 0, "weekly_all")], view: view(snap, inUse: ["tr<i>mo"]))
        XCTAssertEqual(Array(lines(html).prefix(7)), [
            "⚠️ <b>tr&lt;i&gt;mo</b> — Claude weekly at <b>94%</b> · in use on this Mac",
            "• Session 28% · renews in 2h 46m (05:26)",
            "• Weekly 94% · renews in 2d 7h (Mon 10:13)",
            "",
            "👉 Use first: <b>roomy</b> · 47% left · renews in 6d",
            "📈 Most usage left: <b>roomy</b> · 47% left",
            "",
        ])
        XCTAssertFalse(html.contains("<i>mo"), "labels are escaped, not markup")
        XCTAssertTrue(html.contains("tr&lt;i&gt;mo       28% 2h46m  94% 2d7h ⚠ ◀"), html)
    }

    func testAdviceSkipsOptedOutAndStaleAccountsAndSaysWhenNobodyIsFree() {
        let snap = snapshot([claude("cress", session: 69, weekly: 72),
                             claude("roomy", session: 0, weekly: 53, weeklyResets: now.timeIntervalSince1970 + 6 * 86_400),
                             claude("old", session: 0, weekly: 5, age: 20 * 60),
                             claude("full", session: 0, weekly: 100)])
        let excluded: Set<String> = ["claude:roomy@example.com"]
        XCTAssertEqual(UsageAdvice.mostLeft(snap.accounts, tool: "claude", excluded: [], now: now)?.account.label, "roomy",
                       "the most left, not 'old' at 5%: its reading is 20 minutes old")
        XCTAssertEqual(UsageAdvice.mostLeft(snap.accounts, tool: "claude", excluded: excluded, now: now)?.account.label, "cress",
                       "opted out on the dashboard")
        XCTAssertEqual(UsageAdvice.useFirst(snap.accounts, tool: "claude", excluded: excluded, now: now)?.account.label, "cress")
        let dark = snapshot([row("claude", "a", [], error: "Rate Limit"), row("claude", "b", [], error: "token expired — re-login")])
        XCTAssertTrue(UsageText.reportMessage(view(dark)).contains("👉 Use first: no account is free with a fresh reading"))
        let near = snapshot([claude("a", session: 91, weekly: 92), claude("b", session: 100, weekly: 100)])
        XCTAssertTrue(UsageText.reportMessage(view(near)).contains("⏳ All near a limit: <b>a</b> frees up in 2d"),
                      UsageText.reportMessage(view(near)))
    }

    func testAnAlertSendsTheUserElsewhere() throws {
        // cress crossed at exactly 90%, which the dashboard still counts as
        // usable; so does "edge", renewing sooner. Neither is where to go.
        let snap = snapshot([claude("cress", session: 20, weekly: 90),
                             claude("edge", session: 0, weekly: 90, weeklyResets: now.timeIntervalSince1970 + 3600),
                             claude("roomy", session: 0, weekly: 53, weeklyResets: now.timeIntervalSince1970 + 6 * 86_400)])
        let alert = try crossing(snap, 0, "weekly_all")
        let v = view(snap, inUse: ["cress"])
        XCTAssertEqual(v.useFirst(tool: "claude")?.account.label, "edge", "the dashboard's own pick, unchanged")
        XCTAssertTrue(UsageText.alertMessage([alert], view: v).contains("👉 Use first: <b>roomy</b> · 47% left · renews in 6d"))
        XCTAssertEqual(UsageText.notification(for: [alert], view: v).body, "Use first: roomy (47% left).")
        XCTAssertTrue(UsageText.reportMessage(v).contains("👉 Use first: <b>edge</b> · 10% left"), "the report mirrors the dashboard")

        // Every account full: when work can go on, and where.
        let full = snapshot([claude("cress", session: 20, weekly: 95),
                             claude("other", session: 0, weekly: 100, weeklyResets: now.timeIntervalSince1970 + 3 * 3600)])
        let fullAlert = try crossing(full, 0, "weekly_all")
        XCTAssertTrue(UsageText.alertMessage([fullAlert], view: view(full, inUse: ["cress"]))
            .contains("⏳ All near a limit: <b>other</b> frees up in 3h"))
        XCTAssertEqual(UsageText.notification(for: [fullAlert], view: view(full)).body, "All near a limit; other frees up first.")
    }

    func testTheBanner() throws {
        let snap = snapshot([claude("trimo", session: 28, weekly: 94, weeklyResets: now.timeIntervalSince1970 + 2 * 86_400 + 4 * 3_600 + 60),
                             claude("cresswell", session: 65, weekly: 44)])
        let one = UsageText.notification(for: [try crossing(snap, 0, "weekly_all")], view: view(snap))
        XCTAssertEqual(one.title, "trimo: Claude weekly limit at 94%")
        XCTAssertEqual(one.subtitle, "renews in 2d 4h")
        XCTAssertEqual(one.body, "Use first: cresswell (35% left).")

        let both = snapshot([claude("a", session: 91, weekly: 92), claude("b", session: 100, weekly: 100)])
        let several = UsageText.notification(for: [try crossing(both, 0, "session"), try crossing(both, 0, "weekly_all")], view: view(both))
        XCTAssertEqual(several.title, "2 limits passed 90%")
        XCTAssertEqual(several.subtitle, "a · Claude session 91%, a · Claude weekly 92%")
        XCTAssertEqual(several.body, "All near a limit; a frees up first.")

        let codexSnap = snapshot([codex("nexxaflo", [cwindow("weekly", 95, resets: now.timeIntervalSince1970 + 3600)]),
                                  codex("trimomalaysia", [cwindow("weekly", 23, resets: now.timeIntervalSince1970 + 86_400)]),
                                  claude("trimo", session: 0, weekly: 40)])
        XCTAssertEqual(UsageText.notification(for: [try crossing(codexSnap, 0, "weekly")], view: view(codexSnap)).body,
                       "Use first: trimomalaysia (77% left).", "a Codex account for a Codex alert")

        let refused = snapshot([codex("nexxaflo", [cwindow("usage", 100, resets: nil)])])
        let refusal = try crossing(refused, 0, "usage")
        XCTAssertEqual(UsageText.notification(for: [refusal], view: view(refused)).subtitle, "limit reached")
        XCTAssertTrue(UsageText.alertMessage([refusal], view: view(refused)).hasPrefix("⛔️ <b>nexxaflo</b> — Codex usage at <b>100%</b>"))
    }

    func testAHugeTelegramMessageKeepsWholeBlocksWithinTelegramsLimit() {
        let snap = snapshot((0..<120).map { claude("account-\($0)", session: 95, weekly: 96) }
            + (0..<60).map { row("codex", "codex-\($0)", [window("weekly", 97)]) })
        let alerts = snap.accounts.flatMap { account in
            account.windows.filter { $0.pct >= 90 }.map { UsageAlert(account: account, window: $0) }
        }
        let html = UsageText.alertMessage(alerts, view: view(snap))
        XCTAssertLessThanOrEqual(html.utf16.count, UsageText.telegramBudget)
        for tag in ["pre", "b"] {
            XCTAssertEqual(html.components(separatedBy: "<\(tag)>").count, html.components(separatedBy: "</\(tag)>").count,
                           "every <\(tag)> is closed")
        }
        XCTAssertTrue(html.hasPrefix("⚠️ <b>account-0</b> — Claude session at <b>95%</b>, weekly at <b>96%</b>"), String(html.prefix(90)))
        let tail = lines(html).last ?? ""
        XCTAssertTrue(tail.hasPrefix("…") && tail.hasSuffix("more lines not shown: open the dashboard"), tail)

        let tables = UsageText.tableBlocks(view(snapshot((0..<40).map { claude("a\($0)", session: 1, weekly: 1) }))).joined()
        XCTAssertTrue(tables.contains("a29 "), "30 rows shown")
        XCTAssertFalse(tables.contains("a30 "))
        XCTAssertTrue(tables.contains("…and 10 more</pre>"), tables)
    }

    func testFitKeepsWholeBlocksAndCountsTheRest() {
        let blocks = ["head", String(repeating: "x", count: 50), "<pre>a\nb\nc</pre>", "tail"]
        XCTAssertEqual(UsageText.fit(blocks, budget: 10_000), blocks.joined(separator: "\n"), "all of it, when it fits")
        XCTAssertEqual(UsageText.fit(blocks, budget: 120),
                       "head\n" + String(repeating: "x", count: 50) + "\n…4 more lines not shown: open the dashboard",
                       "the table is left out whole, never cut")
    }

    func testTimesInWords() {
        XCTAssertEqual(UsageText.until(now.addingTimeInterval(-60), now: now), nil, "a renewal that passed is not 'in 1m'")
        XCTAssertEqual(UsageText.compact(now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(UsageText.compact(now.addingTimeInterval(3 * 3600 + 27 * 60), now: now), "3h27m")
        XCTAssertEqual(UsageText.compact(now.addingTimeInterval(21 * 3600 + 37 * 60), now: now), "21h")
        XCTAssertEqual(UsageText.compact(now.addingTimeInterval(2 * 86_400 + 8 * 3600), now: now), "2d8h")
        XCTAssertEqual(UsageText.compact(now.addingTimeInterval(6 * 86_400), now: now), "6d")
        XCTAssertEqual(UsageText.clock(now.addingTimeInterval(3600), now: now, timeZone: utc), "03:40")
        XCTAssertEqual(UsageText.clock(now.addingTimeInterval(2 * 86_400), now: now, timeZone: utc), "Mon 02:40")
        XCTAssertEqual(UsageText.clock(now.addingTimeInterval(8 * 86_400), now: now, timeZone: utc), "18 Oct 02:40")
        let idle = UsageWindow(kind: "session", label: "Session (5hr)", pct: 0)
        XCTAssertEqual(UsageText.renewal(idle, view: view(snapshot([]))), "not started")
    }

    func testDurationsAndMenuRows() throws {
        XCTAssertEqual(UsageText.until(now.addingTimeInterval(2 * 86_400 + 4 * 3_600 + 59), now: now), "2d 4h")
        XCTAssertEqual(UsageText.until(now.addingTimeInterval(3 * 3_600 + 10 * 60), now: now), "3h 10m")
        XCTAssertEqual(UsageText.until(now.addingTimeInterval(20), now: now), "1m")
        XCTAssertNil(UsageText.until(nil, now: now))
        let snap = snapshot([claude("trimo", session: 28, weekly: 94), row("claude", "dead", [], error: "x")])
        XCTAssertEqual(UsageText.menuRow(try account(snap, 0)), "trimo — weekly 94% · session 28%", "unused Fable window hidden")
        XCTAssertEqual(UsageText.menuRow(try account(snap, 1)), "dead — not readable")
        XCTAssertEqual(UsageText.html("a&b<c>"), "a&amp;b&lt;c&gt;")
    }
}
