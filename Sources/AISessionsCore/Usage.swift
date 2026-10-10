import Foundation

// Usage limits (Claude session / weekly, Codex weekly) as the ai-accounts
// dashboard reports them. The dashboard owns the accounts' OAuth tokens and
// their refresh — Anthropic's refresh token is single-use, so a second
// refresher would kill accounts — which is why this side only ever reads its
// `GET /data.json` (the last scan, served without a new upstream call).

/// One limit window of one account, e.g. Claude "weekly_all" at 94%.
public struct UsageWindow: Equatable, Codable, Sendable {
    /// "session", "weekly_all", "weekly_scoped" (Claude), "weekly" (Codex)…
    public var kind: String
    /// The dashboard's own label, e.g. "Weekly (7 day)".
    public var label: String
    public var pct: Double
    public var resetsAt: Date?
    /// The dashboard's note when this number is not a fresh reading: "window
    /// reset, no activity since" (an inferred 0) or "stale — account ran
    /// after this reading" (an old number kept).
    public var inferred: String?

    public init(kind: String, label: String, pct: Double, resetsAt: Date? = nil, inferred: String? = nil) {
        self.kind = kind
        self.label = label
        self.pct = pct
        self.resetsAt = resetsAt
        self.inferred = inferred
    }

    /// An old number the dashboard kept although the account ran since:
    /// as far as alerts go, no reading at all.
    public var isStale: Bool { inferred?.lowercased().hasPrefix("stale") == true }

    /// A reading of a period still running at `date`: not stale and not past
    /// its reset. Only these alert, re-arm, or count as over the threshold;
    /// a finished period is history, not news.
    public func isCurrent(at date: Date) -> Bool {
        !isStale && (resetsAt.map { $0 > date } ?? true)
    }

    /// At or over `threshold` (rounded as the dashboard rounds) in a running period.
    public func isOver(_ threshold: Double, at date: Date) -> Bool {
        isCurrent(at: date) && pct.rounded() >= threshold
    }

    /// How much is used now: a period whose reset has passed starts again from 0.
    func used(at date: Date) -> Double {
        resetsAt.map { $0 <= date } == true ? 0 : pct
    }

    /// "session", "weekly", "weekly Fable": what a person calls this window.
    public var shortName: String {
        switch kind {
        case "session": return "session"
        case "weekly_all", "weekly": return "weekly"
        case "weekly_scoped": return label.lowercased() // "weekly fable"
        default: return label.isEmpty ? kind : label.lowercased()
        }
    }
}

/// One account the dashboard tracks (a Claude profile or a Codex home).
public struct UsageAccount: Equatable, Codable, Sendable {
    /// "claude" or "codex".
    public var tool: String
    public var label: String
    public var windows: [UsageWindow]
    /// The dashboard could read this account's limits (not signed out, not erroring).
    public var readable: Bool
    /// The account's sign-in address, as the dashboard read it from the profile.
    public var email: String?
    /// When the dashboard took this reading (`limits.as_of`).
    public var asOf: Date?
    /// The dashboard's own words when it could not read the limits.
    public var error: String?

    public init(tool: String, label: String, windows: [UsageWindow], readable: Bool = true, email: String? = nil,
                asOf: Date? = nil, error: String? = nil) {
        self.tool = tool
        self.label = label
        self.windows = windows
        self.readable = readable
        self.email = email
        self.asOf = asOf
        self.error = error
    }

    public var toolName: String { tool == "codex" ? "Codex" : "Claude" }

    /// "claude|trimo": one account of one tool, as the dashboard lists it.
    public var key: String { "\(tool)|\(label)" }

    /// "claude|trimomalaysia@gmail.com": the account itself, which alert
    /// records are kept under. A dashboard label is a folder: it can be
    /// signed in to another account later, and the account this Mac uses can
    /// appear as a passing "project" row as well as its own; the address is
    /// the same in both. A row without one falls back to its label.
    public var recordID: String {
        let identity = email.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        return "\(tool)|\(identity ?? label)"
    }

    /// What to call the account: its label, or its address for the
    /// dashboard's "project" row (this Mac's account when it has no profile).
    public var name: String { label == "project" ? (email ?? label) : label }

    /// A Claude account signed in where the user's sessions run.
    public func isSignedIn(_ emails: Set<String>?) -> Bool {
        guard tool == "claude", let email = email?.lowercased(), let emails else { return false }
        return emails.contains(email)
    }

    /// The fullest window, the one that will stop this account first.
    public var binding: UsageWindow? { windows.max { $0.pct < $1.pct } }

    func window(_ kind: String) -> UsageWindow? { windows.first { $0.kind == kind } }

    /// Readable, with a window at or over `threshold` in a running period.
    public func isOver(_ threshold: Double, at date: Date) -> Bool {
        readable && windows.contains { $0.isOver(threshold, at: date) }
    }
}

/// What the dashboard said at one moment.
public struct UsageSnapshot: Equatable, Sendable {
    public var accounts: [UsageAccount]
    public var fetchedAt: Date

    public init(accounts: [UsageAccount], fetchedAt: Date) {
        self.accounts = accounts
        self.fetchedAt = fetchedAt
    }

    /// Parses the dashboard's `/data.json`: `{"rows": [{"tool", "label",
    /// "skipped", "limits": {"error", "windows": [{"kind", "label", "pct",
    /// "resets"}]}}], "meta": {…}}`. Excluded accounts and windows without a
    /// number are left out; nil if the shape is not that.
    public static func parse(_ data: Data, fetchedAt: Date) -> UsageSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["rows"] as? [Any] else { return nil }
        var accounts: [UsageAccount] = []
        for case let row as [String: Any] in rows {
            guard let tool = row["tool"] as? String, let label = row["label"] as? String,
                  !isLeftOut(row["skipped"]) else { continue }
            let limits = row["limits"] as? [String: Any] ?? [:]
            var windows: [UsageWindow] = []
            for case let window as [String: Any] in limits["windows"] as? [Any] ?? [] {
                // A number, not a JSON true/false (which NSNumber also carries).
                guard let kind = window["kind"] as? String, let number = window["pct"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), case let pct = number.doubleValue,
                      pct.isFinite else { continue }
                let resets = (window["resets"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                // Bounded: a wild number must not trap `Int(pct.rounded())`.
                windows.append(UsageWindow(kind: kind, label: window["label"] as? String ?? kind,
                                           pct: min(max(pct, 0), 1000), resetsAt: resets,
                                           inferred: window["inferred"] as? String))
            }
            let error = limits["error"] as? String
            let readable = (error?.isEmpty ?? true) && !windows.isEmpty
            let asOf = (limits["as_of"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            accounts.append(UsageAccount(tool: tool, label: label, windows: windows, readable: readable,
                                         email: row["email"] as? String, asOf: asOf,
                                         error: error.flatMap { $0.isEmpty ? nil : $0 }))
        }
        return UsageSnapshot(accounts: accounts, fetchedAt: fetchedAt)
    }

    /// `skipped` is the dashboard's note on its token-cost scan ("signed in —
    /// no usage recorded yet"), not on the limits, which it reads anyway. Only
    /// an excluded account is left out (the dashboard withholds its limits on
    /// purpose), or a row marked plainly `true`.
    static func isLeftOut(_ skipped: Any?) -> Bool {
        if let reason = skipped as? String { return reason.hasPrefix("excluded") }
        return skipped as? Bool == true
    }

    /// Accounts with a window at or over `threshold` now.
    public func over(_ threshold: Double) -> [UsageAccount] {
        accounts.filter { $0.isOver(threshold, at: fetchedAt) }
    }

    /// The same reading, cut down to the accounts `keep` accepts.
    public func only(_ keep: (UsageAccount) -> Bool) -> UsageSnapshot {
        UsageSnapshot(accounts: accounts.filter(keep), fetchedAt: fetchedAt)
    }
}

/// Whose limits alert (config `usageAlertAccounts`). "current": the Claude
/// account each watched config dir is signed into, i.e. the one the user's
/// sessions run under; "all": every account; anything else names an account
/// by its dashboard label ("trimo"), tool and label ("codex:nexxaflo") or
/// sign-in email. Case does not matter.
public struct UsageAlertScope: Equatable, Sendable {
    public var everyAccount = false
    public var current = false
    public var named: Set<String> = []

    public init(_ entries: [String]) {
        for raw in entries {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch entry {
            case "": continue
            case "all": everyAccount = true
            case "current": current = true
            default: named.insert(entry)
            }
        }
    }

    /// Who is signed in decides what is covered: until that is known, nothing
    /// is evaluated (a guess would forget the real account's alerts).
    public var needsSignedIn: Bool { current && !everyAccount }

    /// Whether `account`'s crossings alert, given the emails signed in now.
    public func covers(_ account: UsageAccount, signedIn: Set<String>?) -> Bool {
        if everyAccount { return true }
        if current, account.isSignedIn(signedIn) { return true }
        let label = account.label.lowercased()
        return named.contains(label) || named.contains("\(account.tool):\(label)")
            || account.email.map { named.contains($0.lowercased()) } == true
    }
}

/// A window that just crossed the threshold.
public struct UsageAlert: Equatable, Sendable {
    public var account: UsageAccount
    public var window: UsageWindow

    public init(account: UsageAccount, window: UsageWindow) {
        self.account = account
        self.window = window
    }

    /// Stable per account and window (not per reset): the notification
    /// identifier, so a newer alert for the same window replaces the older.
    /// A scoped weekly limit is one per model or surface ("Weekly Opus",
    /// "Weekly Fable"), all of kind "weekly_scoped": its label tells them apart.
    public var key: String { "\(account.key)|\(windowKey)" }

    /// The same window of the account itself, which its record is kept under.
    public var recordKey: String { "\(account.recordID)|\(windowKey)" }

    private var windowKey: String {
        let scope = window.kind == "weekly_scoped" ? ":" + window.label.replacingOccurrences(of: "|", with: "/") : ""
        return window.kind + scope
    }
}

/// Decides which windows are news: edge-triggered, like the dashboard's own
/// Discord alert. A window alerts once when it reaches the threshold and not
/// again until it drops back below (its reset) or a new window period begins.
/// What was alerted is persisted, so a restart does not repeat it; the very
/// first run only records what is already over (six accounts sat at 100% on
/// the day this was built — that is not news).
/// Not thread-safe: call it from one queue.
public final class UsageAlertEngine {
    struct Record: Codable, Equatable {
        var resetsAt: Date?
        var pct: Double
        var alertedAt: Date
    }

    struct State: Codable, Equatable {
        var initialized = false
        var alerted: [String: Record] = [:]
    }

    /// Two readings of one window period may disagree on its reset time by a
    /// little (Codex's is derived from "resets in N s"); a period is at least
    /// five hours, so anything closer than this is the same period.
    static let samePeriodTolerance: TimeInterval = 15 * 60

    public var threshold: Double
    let url: URL
    private(set) var state: State
    private let now: () -> Date

    public init(url: URL, threshold: Double = 90, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.threshold = threshold
        self.now = now
        state = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(State.self, from: $0) } ?? State()
    }

    public static func standard(threshold: Double) -> UsageAlertEngine {
        UsageAlertEngine(url: AppPaths.stateDir.appendingPathComponent("usage-alerts.json"), threshold: threshold)
    }

    /// The first evaluation of a brand-new state only records.
    public var isFirstRun: Bool { !state.initialized }

    /// The windows that crossed the threshold since the last call, in the
    /// snapshot's order. Unreadable accounts neither alert nor re-arm: a
    /// signed-out profile reporting nothing has not dropped below anything.
    /// The very first call records every listed account, readable or not: an
    /// account the dashboard could not refresh shows its last real numbers,
    /// and one held back by a 429 is often one at its cap.
    /// Every account is evaluated, so each keeps its own edge whether or not
    /// its limits alert; the caller announces the ones it follows (and
    /// `forget`s an account it starts following).
    public func evaluate(_ snapshot: UsageSnapshot) -> [UsageAlert] {
        let announce = state.initialized
        let at = snapshot.fetchedAt
        var alerts: [UsageAlert] = []
        var next = state
        Self.moveLegacyRecords(&next, to: snapshot)
        for account in snapshot.accounts where account.readable || !announce {
            var seen = Set<String>()
            for alert in Self.distinctWindows(of: account, at: at) {
                let window = alert.window
                seen.insert(alert.recordKey)
                // An old number kept, or a period already over: history. Codex
                // reports both right after a reset (an inferred 0, then the old
                // number again once a run starts without a reading).
                guard window.isCurrent(at: at) else { continue }
                let record = next.alerted[alert.recordKey]
                guard window.pct.rounded() >= threshold else {
                    // Armed again by a reading of the recorded period, or once
                    // that period is over. A lower number with another reset
                    // before then is a different limit (Codex shows the one its
                    // last run hit, sometimes another limit at 0%).
                    if let record, Self.samePeriod(record.resetsAt, window.resetsAt) || Self.ended(record, at: at) {
                        next.alerted[alert.recordKey] = nil
                    }
                    continue
                }
                if let record, Self.samePeriod(record.resetsAt, window.resetsAt) { continue }
                // Codex drops the date from "try again at …" on the reset's own
                // day: no reset, inside a dated period not yet over, is that period.
                if let record, window.resetsAt == nil, record.resetsAt != nil, !Self.ended(record, at: at) { continue }
                next.alerted[alert.recordKey] = Record(resetsAt: window.resetsAt, pct: window.pct, alertedAt: now())
                if announce { alerts.append(alert) }
            }
            // A window without a reset that a readable account no longer
            // reports (a Codex refusal, gone once a run succeeds) is armed again.
            if account.readable {
                let part = account.recordID
                for (key, record) in next.alerted
                where record.resetsAt == nil && !seen.contains(key) && Self.accountPart(of: key) == part {
                    next.alerted[key] = nil
                }
            }
        }
        // An account the dashboard no longer lists keeps its records until
        // their period is over: a row can miss one scan (a profile not read,
        // the "project" row of a login in progress), and coming back must not
        // make an old crossing news. An unreadable one keeps its records too.
        let listed = Set(snapshot.accounts.map(\.recordID))
        next.alerted = next.alerted.filter { key, record in
            listed.contains(Self.accountPart(of: key)) || !Self.lapsed(record, at: at)
        }
        next.initialized = true
        if next != state {
            state = next
            save()
        }
        return alerts
    }

    /// Makes accounts (by `recordID`) news again: their windows over the
    /// threshold alert at the next evaluation. For an account just signed in
    /// to, which may have crossed while the alerts followed another one.
    public func forget(_ ids: Set<String>) {
        guard state.alerted.keys.contains(where: { ids.contains(Self.accountPart(of: $0)) }) else { return }
        state.alerted = state.alerted.filter { !ids.contains(Self.accountPart(of: $0.key)) }
        save()
    }

    /// Records kept under a dashboard label (before they were kept under the
    /// account's address) move to the address the row now shows.
    static func moveLegacyRecords(_ state: inout State, to snapshot: UsageSnapshot) {
        for account in snapshot.accounts where account.recordID != account.key {
            for (key, record) in state.alerted where accountPart(of: key) == account.key {
                let window = key.dropFirst(account.key.count) // "|weekly_all"
                state.alerted[key] = nil
                let moved = account.recordID + window
                if state.alerted[moved] == nil { state.alerted[moved] = record }
            }
        }
    }

    /// A record of an account no longer listed may go: its period is over,
    /// or (no reset to tell) it is more than a week old.
    static func lapsed(_ record: Record, at date: Date) -> Bool {
        record.resetsAt == nil ? date.timeIntervalSince(record.alertedAt) > 8 * 86_400 : ended(record, at: date)
    }

    /// One alert per key. Should two windows share one (a meter the server
    /// adds before it has a label of its own), the current, fuller one speaks
    /// for both, so they cannot record and clear each other on every poll.
    static func distinctWindows(of account: UsageAccount, at date: Date) -> [UsageAlert] {
        var order: [String] = []
        var best: [String: UsageAlert] = [:]
        for window in account.windows {
            let alert = UsageAlert(account: account, window: window)
            guard let held = best[alert.recordKey] else {
                order.append(alert.recordKey)
                best[alert.recordKey] = alert
                continue
            }
            let candidate = (window.isCurrent(at: date), window.pct)
            let current = (held.window.isCurrent(at: date), held.window.pct)
            if (candidate.0 ? 1 : 0, candidate.1) > (current.0 ? 1 : 0, current.1) { best[alert.recordKey] = alert }
        }
        return order.compactMap { best[$0] }
    }

    /// The recorded period is over: its reset passed (give or take the tolerance).
    static func ended(_ record: Record, at date: Date) -> Bool {
        guard let reset = record.resetsAt else { return false }
        return date >= reset.addingTimeInterval(-samePeriodTolerance)
    }

    /// "claude|a@b.com|weekly_all" → "claude|a@b.com".
    static func accountPart(of key: String) -> String {
        guard let bar = key.lastIndex(of: "|") else { return key }
        return String(key[..<bar])
    }

    static func samePeriod(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= samePeriodTolerance
        default: return false
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            Log.shared.error("could not save \(url.path): \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// What the words of a usage message depend on: the reading, whose limits
/// alert, which accounts this Mac uses, and the dashboard's opt-outs.
public struct UsageView: Sendable {
    public var snapshot: UsageSnapshot
    public var threshold: Double
    /// The accounts whose limits alert, in the dashboard's order.
    public var followed: [UsageAccount]
    /// Keys of the accounts this Mac's sessions are signed into.
    public var inUse: Set<String>
    /// Whether this Mac's sign-in could be read at all.
    public var signedInKnown: Bool
    /// The dashboard's "Use first" opt-outs (`.suggest-exclude.json`).
    public var excluded: Set<String>
    /// For clock times ("renews in 3h 27m (13:50)").
    public var timeZone: TimeZone
    /// For an alert's view (`leaving`): the opt-outs before the crossing
    /// accounts were left out, to say which account frees up first when no
    /// other one is free.
    var ownExcluded: Set<String>?
    /// The moment the words are for: "renews in" counts from it, and a
    /// reading older than 15 minutes is no base for advice. The reading's
    /// own time unless told otherwise (a report asked for later).
    public var now: Date
    /// Set when the dashboard stopped answering: the reading is the last good one.
    public var dashboardDown: Bool
    /// Whether the setting follows the account this Mac is signed into.
    public var followsSignIn: Bool

    public init(snapshot: UsageSnapshot, threshold: Double, followed: [UsageAccount] = [], inUse: Set<String> = [],
                signedInKnown: Bool = true, excluded: Set<String> = [], timeZone: TimeZone = .current,
                now: Date? = nil, dashboardDown: Bool = false, followsSignIn: Bool = true) {
        self.snapshot = snapshot
        self.threshold = threshold
        self.followed = followed
        self.inUse = inUse
        self.signedInKnown = signedInKnown
        self.excluded = excluded
        self.timeZone = timeZone
        self.now = now ?? snapshot.fetchedAt
        self.dashboardDown = dashboardDown
        self.followsSignIn = followsSignIn
    }

    /// The reading is old enough to say so: the dashboard is down, or it is
    /// more than two polls old (the Mac slept).
    public var readingIsOld: Bool { dashboardDown || now.timeIntervalSince(snapshot.fetchedAt) > 150 }

    /// The dashboard's pick for `tool`, optionally passing over one account
    /// (the one in use, for "then").
    public func useFirst(tool: String, excluding skip: UsageAccount? = nil) -> UseFirst? {
        var excluded = self.excluded
        if let skip { excluded.insert(UsageAdvice.exclusionKey(skip)) }
        return UsageAdvice.useFirst(snapshot.accounts, tool: tool, excluded: excluded, now: now)
    }

    public func mostLeft(tool: String) -> (account: UsageAccount, left: Int)? {
        UsageAdvice.mostLeft(snapshot.accounts, tool: tool, excluded: excluded, now: now)
    }

    /// When every account is near a limit: the one that frees up first
    /// (the crossing accounts count here).
    public func freesUpFirst(tool: String) -> UseFirst? {
        UsageAdvice.freesUpFirst(snapshot.accounts, tool: tool, excluded: ownExcluded ?? excluded, now: now)
    }

    /// The same view for an alert: advice that sends the user somewhere
    /// else. Every account at or over the threshold is left out: the ones
    /// that just crossed, and any already there (the dashboard still counts
    /// 90% as usable; switching to it would alert at once).
    public func leaving() -> UsageView {
        var view = self
        view.ownExcluded = ownExcluded ?? excluded
        for account in snapshot.accounts where account.isOver(threshold, at: now) {
            view.excluded.insert(UsageAdvice.exclusionKey(account))
        }
        return view
    }
}

/// The words of a usage alert: the macOS banner, the Telegram message and the
/// menu lines. Pure, so every wording is pinned by a test.
public enum UsageText {
    /// "2d 4h", "3h 10m", "45m"; nil without a date or once it has passed.
    public static func until(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(m, 1))m"
    }

    static func percent(_ pct: Double) -> String { "\(Int(pct.rounded()))%" }

    /// "trimo · Claude weekly 94%".
    public static func headline(_ alert: UsageAlert) -> String {
        "\(alert.account.name) · \(alert.account.toolName) \(alert.window.shortName) \(percent(alert.window.pct))"
    }

    /// The macOS banner for one tick's crossings: what crossed, when it
    /// renews, and the account to use first (the dashboard's own pick).
    public static func notification(for alerts: [UsageAlert], view: UsageView)
        -> (title: String, subtitle: String, body: String) {
        let elsewhere = view.leaving()
        let advice = adviceTool(view, alerts: alerts).map { tool -> String in
            guard let pick = elsewhere.useFirst(tool: tool) ?? elsewhere.freesUpFirst(tool: tool) else {
                return "No \(toolName(tool)) account has a fresh reading."
            }
            switch pick.mode {
            case .safe: return "Use first: \(pick.account.name) (\(pick.left)% left)."
            case .fallback: return "All near a limit; \(pick.account.name) frees up first."
            }
        } ?? ""
        guard alerts.count == 1, let alert = alerts.first else {
            // "trimo: session 91%, weekly 92% · cress: weekly 100%"
            var names: [String] = []
            var parts: [String: [String]] = [:]
            for alert in alerts {
                if parts[alert.account.name] == nil { names.append(alert.account.name) }
                parts[alert.account.name, default: []].append("\(alert.window.shortName) \(percent(alert.window.pct))")
            }
            let subtitle = names.map { "\($0): " + (parts[$0] ?? []).joined(separator: ", ") }.joined(separator: " · ")
            return ("\(alerts.count) limits at \(percent(view.threshold))+", subtitle, advice)
        }
        // The number first: a one-line title is cut at its end.
        let renews = until(alert.window.resetsAt, now: view.now).map { " · renews in \($0)" }
            ?? (alert.window.pct.rounded() >= 100 ? " · limit reached" : "")
        return ("\(alert.account.toolName) \(alert.window.shortName) limit at \(percent(alert.window.pct))",
                alert.account.name + renews, advice)
    }

    /// What one Telegram message may hold: Telegram takes 4096 UTF-16 units
    /// (after parsing, so the tags here only make this cautious).
    public static let telegramBudget = 4000
    /// Rows per table before "…and N more" (eleven accounts today).
    static let maxTableRows = 30

    /// The Telegram alert (parse_mode HTML) for one tick's crossings, in the
    /// user's layout: what crossed, every account's limits with when they
    /// renew, then the account to use first and the one with the most usage
    /// left, by name.
    ///
    ///     ⚠️ cresswell-nexxatech — Claude weekly at 91%
    ///
    ///     Claude Code
    ///     <table>
    ///     Codex
    ///     <table>
    ///
    ///     Use first: looiytube2
    ///     Most usage left: looiytube2
    public static func alertMessage(_ alerts: [UsageAlert], view: UsageView) -> String {
        var blocks: [String] = []
        var seen: [String] = []
        for alert in alerts where !seen.contains(alert.account.key) {
            seen.append(alert.account.key)
            let mine = alerts.filter { $0.account.key == alert.account.key }
            let crossed = mine.map { "\(html($0.window.shortName)) at <b>\(percent($0.window.pct))</b>" }.joined(separator: ", ")
            let reached = mine.contains { $0.window.pct.rounded() >= 100 }
            blocks.append("\(reached ? "⛔️" : "⚠️") <b>\(html(alert.account.name))</b> — \(alert.account.toolName) \(crossed)")
        }
        blocks.append("")
        blocks += tableBlocks(view)
        blocks.append("")
        blocks += adviceLines(view.leaving(), tools: adviceTool(view, alerts: alerts).map { [$0] } ?? [])
        return fit(blocks)
    }

    /// The usage report, in the same layout: every account's limits with when
    /// they renew, then use first and most usage left. `lead` replaces the
    /// "📊 AI usage" title.
    public static func reportMessage(_ view: UsageView, lead: String? = nil) -> String {
        var blocks = [lead ?? "📊 <b>AI usage</b> · \(clock(view.now, now: view.now, timeZone: view.timeZone))"]
        if view.readingIsOld {
            let age = until(view.now, now: view.snapshot.fetchedAt).map { " (\($0) ago)" } ?? ""
            blocks.append("⚠️ " + (view.dashboardDown ? "The dashboard is not answering: " : "")
                + "these numbers are from \(clock(view.snapshot.fetchedAt, now: view.now, timeZone: view.timeZone))\(age).")
        }
        if view.followed.isEmpty {
            if view.followsSignIn {
                blocks.append(view.signedInKnown ? "No account on the dashboard matches the one this Mac is signed into."
                                                 : "Can't tell which Claude account this Mac is signed into.")
            } else {
                blocks.append("usageAlertAccounts names no account on the dashboard.")
            }
        }
        blocks.append("")
        blocks += tableBlocks(view)
        blocks.append("")
        var tools = view.followed.map(\.tool).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if tools.isEmpty { tools = ["claude"] }
        // As in an alert: an account at the threshold is no place to go, even
        // though the dashboard still counts 90% as usable.
        blocks += adviceLines(view.leaving(), tools: tools)
        return fit(blocks)
    }

    /// "Use first: looiytube2" and "Most usage left: looiytube2", per tool,
    /// names only. When no account is free (an alert's view leaves out every
    /// account at the threshold), use first is the one that frees up first.
    static func adviceLines(_ view: UsageView, tools: [String]) -> [String] {
        var lines: [String] = []
        for tool in tools {
            let name = tools.count > 1 ? " (\(toolName(tool)))" : ""
            let pick = view.useFirst(tool: tool) ?? (view.ownExcluded == nil ? nil : view.freesUpFirst(tool: tool))
            lines.append("Use first\(name): " + (pick.map { "<b>\(html($0.account.name))</b>" } ?? "—"))
            lines.append("Most usage left\(name): " + (view.mostLeft(tool: tool).map { "<b>\(html($0.account.name))</b>" } ?? "—"))
        }
        return lines
    }

    /// Which tool's accounts to advise on for these alerts: Claude first.
    static func adviceTool(_ view: UsageView, alerts: [UsageAlert]) -> String? {
        if alerts.contains(where: { $0.account.tool == "claude" }) { return "claude" }
        return alerts.first?.account.tool
    }

    static func toolName(_ tool: String) -> String { tool == "codex" ? "Codex" : "Claude" }

    /// Every account's limits with when they renew, as monospaced tables:
    /// the accounts this Mac uses first (◀), ⚠ at the threshold, ? unreadable.
    ///     account       session    week
    ///     cresswell-nex 64% 3h27m  70% 21h ◀
    /// Columns are as wide as their widest cell (by screen width, so a label
    /// in CJK or with an emoji keeps the rest aligned).
    static func tableBlocks(_ view: UsageView) -> [String] {
        let now = view.now
        let ordered = view.snapshot.accounts.enumerated().sorted { lhs, rhs in
            let l = view.inUse.contains(lhs.element.key), r = view.inUse.contains(rhs.element.key)
            return l != r ? l : lhs.offset < rhs.offset
        }.map(\.element)
        let names = shortNames(ordered.map(\.name))
        // "77% 3h10m": used, then when it renews. A number that is not a
        // reading of the running period (old, or its period over) gets a "?".
        func cell(_ window: UsageWindow?, renewal: Bool = true) -> String {
            guard let window else { return "-" }
            guard window.isCurrent(at: now) || window.pct == 0 else { return percent(window.pct) + "?" }
            let renews = renewal && window.pct > 0 ? compact(window.resetsAt, now: now).map { " " + $0 } ?? "" : ""
            return percent(window.pct) + renews
        }
        func marks(_ account: UsageAccount) -> String {
            let state = account.readable ? (account.isOver(view.threshold, at: now) ? " ⚠" : "") : " ?"
            return state + (view.inUse.contains(account.key) ? " ◀" : "")
        }
        var out: [String] = []
        let claude = ordered.enumerated().filter { $0.element.tool == "claude" }
        if !claude.isEmpty {
            // The Fable column (by its label) only once some account uses it;
            // its renewal is the week's, so it shows the number alone.
            func fable(_ account: UsageAccount) -> UsageWindow? {
                account.windows.first { $0.kind == "weekly_scoped" && $0.label.lowercased().contains("fable") }
            }
            let showFable = claude.contains { ($0.element.windows.contains { $0.kind == "weekly_scoped" && $0.label.lowercased().contains("fable") && $0.pct > 0 }) }
            var rows = [["account", "session", "week"] + (showFable ? ["fable"] : [])]
            for (index, account) in claude {
                rows.append([names[index], cell(account.window("session")), cell(account.window("weekly_all"))]
                            + (showFable ? [cell(fable(account), renewal: false)] : []))
            }
            let lines = aligned(rows)
            out.append("<b>Claude Code</b>")
            out.append(table([lines[0]] + capped(zip(lines.dropFirst(), claude).map { $0 + marks($1.element) })))
        }
        let codex = ordered.enumerated().filter { $0.element.tool == "codex" }
        if !codex.isEmpty {
            let lines = aligned(codex.map { [names[$0.offset], cell(UsageAdvice.renewal($0.element))] })
            out.append("<b>Codex</b>")
            out.append(table(capped(zip(lines, codex).map { $0 + marks($1.element) })))
        }
        return out
    }

    /// Rows of cells as lines, each column as wide as its widest cell plus a space.
    static func aligned(_ rows: [[String]]) -> [String] {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            rows.map { column < $0.count ? width($0[column]) : 0 }.max() ?? 0
        }
        return rows.map { row in
            var line = ""
            for (column, cell) in row.enumerated() {
                line += cell
                if column < row.count - 1 { line += String(repeating: " ", count: widths[column] - width(cell) + 1) }
            }
            return line
        }
    }

    /// Labels cut to 13 columns; two that would read the same keep their
    /// own endings ("cresswell-…ch", "cresswell-…lo").
    static func shortNames(_ names: [String], max: Int = 13) -> [String] {
        func cut(_ name: String, to columns: Int) -> String {
            var out = ""
            for character in name {
                guard width(out) + width(String(character)) <= columns else { break }
                out.append(character)
            }
            return out
        }
        let plain = names.map { width($0) <= max ? $0 : cut($0, to: max) }
        return names.enumerated().map { index, name in
            let short = plain[index]
            guard short != name, plain.enumerated().contains(where: { $0.offset != index && $0.element == short }) else { return short }
            return cut(name, to: max - 3) + "…" + String(name.suffix(2))
        }
    }

    /// Columns a monospaced font gives `text`: East Asian wide characters
    /// and emoji take two.
    static func width(_ text: String) -> Int {
        text.reduce(0) { total, character in
            let scalars = character.unicodeScalars
            let wide = scalars.contains { scalar in
                scalar.properties.isEmojiPresentation
                    || (0x1100...0x115F).contains(scalar.value) || (0x2E80...0xA4CF).contains(scalar.value)
                    || (0xAC00...0xD7A3).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
                    || (0xFE30...0xFE4F).contains(scalar.value) || (0xFF00...0xFF60).contains(scalar.value)
                    || (0xFFE0...0xFFE6).contains(scalar.value) || (0x20000...0x3FFFD).contains(scalar.value)
            }
            return total + (wide ? 2 : 1)
        }
    }

    /// "45m", "3h27m", "21h", "2d8h": a renewal time that fits a table cell.
    static func compact(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        if minutes < 600 { return "\(minutes / 60)h\(minutes % 60 > 0 ? "\(minutes % 60)m" : "")" }
        if minutes < 48 * 60 { return "\(minutes / 60)h" }
        let days = minutes / 1440, hours = (minutes % 1440) / 60
        return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
    }

    /// "13:50" today, "Sun 07:59" within the week, "12 Oct 07:59" beyond.
    static func clock(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            formatter.dateFormat = "EEE HH:mm"
        } else {
            formatter.dateFormat = "d MMM HH:mm"
        }
        return formatter.string(from: date)
    }

    private static func table(_ rows: [String]) -> String {
        "<pre>" + html(rows.joined(separator: "\n")) + "</pre>"
    }

    private static func capped(_ rows: [String]) -> [String] {
        rows.count <= maxTableRows ? rows : Array(rows.prefix(maxTableRows)) + ["…and \(rows.count - maxTableRows) more"]
    }

    /// Joins whole blocks while they fit in `budget` (UTF-16 units, as
    /// Telegram counts). Never a cut: one inside a tag or a `<pre>` makes
    /// Telegram refuse the whole message. What is left out is counted on a
    /// last line.
    static func fit(_ blocks: [String], budget: Int = telegramBudget) -> String {
        let tailRoom = 64
        var kept: [String] = []
        var used = 0
        for (index, block) in blocks.enumerated() {
            let cost = block.utf16.count + (kept.isEmpty ? 0 : 1)
            let isLast = index == blocks.count - 1
            if used + cost <= budget - (isLast ? 0 : tailRoom) {
                kept.append(block)
                used += cost
                continue
            }
            let left = blocks[index...].reduce(0) { $0 + $1.split(separator: "\n", omittingEmptySubsequences: false).count }
            kept.append("…\(left) more line\(left == 1 ? "" : "s") not shown: open the dashboard")
            break
        }
        return kept.joined(separator: "\n")
    }

    /// One menu row: "trimo — weekly 94% · session 27%".
    public static func menuRow(_ account: UsageAccount) -> String {
        "\(account.name) — " + windows(account)
    }

    /// "cresswell-nexxatech at 66% weekly · 50% session": the account and its
    /// limits, fullest first (an unused Fable window left out).
    public static func atUsage(_ account: UsageAccount) -> String {
        guard account.readable else { return "\(account.name) (not readable)" }
        let parts = account.windows
            .filter { $0.kind != "weekly_scoped" || $0.pct > 0 }
            .sorted { $0.pct > $1.pct }
            .map { "\(percent($0.pct)) \($0.shortName)" }
        return parts.isEmpty ? account.name : "\(account.name) at " + parts.joined(separator: " · ")
    }

    /// "weekly 94% · session 27%", fullest first; "not readable".
    public static func windows(_ account: UsageAccount) -> String {
        guard account.readable else { return "not readable" }
        return account.windows
            .filter { $0.kind != "weekly_scoped" || $0.pct > 0 }
            .sorted { $0.pct > $1.pct }
            .map { "\($0.shortName) \(percent($0.pct))" }
            .joined(separator: " · ")
    }

    /// Escapes text for Telegram's HTML parse mode.
    public static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
