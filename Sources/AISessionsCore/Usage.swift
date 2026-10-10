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

    public init(tool: String, label: String, windows: [UsageWindow], readable: Bool = true) {
        self.tool = tool
        self.label = label
        self.windows = windows
        self.readable = readable
    }

    public var toolName: String { tool == "codex" ? "Codex" : "Claude" }

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
                guard let kind = window["kind"] as? String, let pct = (window["pct"] as? NSNumber)?.doubleValue,
                      pct.isFinite else { continue }
                let resets = (window["resets"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                // Bounded: a wild number must not trap `Int(pct.rounded())`.
                windows.append(UsageWindow(kind: kind, label: window["label"] as? String ?? kind,
                                           pct: min(max(pct, 0), 1000), resetsAt: resets,
                                           inferred: window["inferred"] as? String))
            }
            let error = limits["error"] as? String
            let readable = (error?.isEmpty ?? true) && !windows.isEmpty
            accounts.append(UsageAccount(tool: tool, label: label, windows: windows, readable: readable))
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

    /// The account of `tool` with the most room left now: no window over the
    /// threshold, then the lowest weekly, then the lowest session use.
    public func mostRoom(tool: String = "claude", threshold: Double) -> UsageAccount? {
        accounts
            .filter { $0.tool == tool && $0.readable && !$0.isOver(threshold, at: fetchedAt) }
            .min { lhs, rhs in rank(lhs) < rank(rhs) }
    }

    /// Weekly use, then session use, as they stand now.
    func rank(_ account: UsageAccount) -> (Double, Double) {
        let weekly = account.window("weekly_all") ?? account.window("weekly") ?? account.binding
        return (weekly?.used(at: fetchedAt) ?? 0, account.window("session")?.used(at: fetchedAt) ?? 0)
    }

    /// Accounts with a window at or over `threshold` now.
    public func over(_ threshold: Double) -> [UsageAccount] {
        accounts.filter { $0.isOver(threshold, at: fetchedAt) }
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
    public var key: String {
        let scope = window.kind == "weekly_scoped" ? ":" + window.label.replacingOccurrences(of: "|", with: "/") : ""
        return "\(account.tool)|\(account.label)|\(window.kind)\(scope)"
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
    public func evaluate(_ snapshot: UsageSnapshot) -> [UsageAlert] {
        let announce = state.initialized
        let at = snapshot.fetchedAt
        var alerts: [UsageAlert] = []
        var next = state
        for account in snapshot.accounts where account.readable || !announce {
            var seen = Set<String>()
            for alert in Self.distinctWindows(of: account, at: at) {
                let window = alert.window
                seen.insert(alert.key)
                // An old number kept, or a period already over: history. Codex
                // reports both right after a reset (an inferred 0, then the old
                // number again once a run starts without a reading).
                guard window.isCurrent(at: at) else { continue }
                let record = next.alerted[alert.key]
                guard window.pct.rounded() >= threshold else {
                    // Armed again by a reading of the recorded period, or once
                    // that period is over. A lower number with another reset
                    // before then is a different limit (Codex shows the one its
                    // last run hit, sometimes another limit at 0%).
                    if let record, Self.samePeriod(record.resetsAt, window.resetsAt) || Self.ended(record, at: at) {
                        next.alerted[alert.key] = nil
                    }
                    continue
                }
                if let record, Self.samePeriod(record.resetsAt, window.resetsAt) { continue }
                // Codex drops the date from "try again at …" on the reset's own
                // day: no reset, inside a dated period not yet over, is that period.
                if let record, window.resetsAt == nil, record.resetsAt != nil, !Self.ended(record, at: at) { continue }
                next.alerted[alert.key] = Record(resetsAt: window.resetsAt, pct: window.pct, alertedAt: now())
                if announce { alerts.append(alert) }
            }
            // A window without a reset that a readable account no longer
            // reports (a Codex refusal, gone once a run succeeds) is armed again.
            if account.readable {
                let part = "\(account.tool)|\(account.label)"
                for (key, record) in next.alerted
                where record.resetsAt == nil && !seen.contains(key) && Self.accountPart(of: key) == part {
                    next.alerted[key] = nil
                }
            }
        }
        // Accounts the dashboard no longer lists (removed, renamed) are
        // forgotten; an unreadable one keeps its records, so a brief read
        // failure cannot re-announce a window that never went below.
        let listed = Set(snapshot.accounts.map { "\($0.tool)|\($0.label)" })
        next.alerted = next.alerted.filter { listed.contains(Self.accountPart(of: $0.key)) }
        next.initialized = true
        if next != state {
            state = next
            save()
        }
        return alerts
    }

    /// One alert per key. Should two windows share one (a meter the server
    /// adds before it has a label of its own), the current, fuller one speaks
    /// for both, so they cannot record and clear each other on every poll.
    static func distinctWindows(of account: UsageAccount, at date: Date) -> [UsageAlert] {
        var order: [String] = []
        var best: [String: UsageAlert] = [:]
        for window in account.windows {
            let alert = UsageAlert(account: account, window: window)
            guard let held = best[alert.key] else {
                order.append(alert.key)
                best[alert.key] = alert
                continue
            }
            let candidate = (window.isCurrent(at: date), window.pct)
            let current = (held.window.isCurrent(at: date), held.window.pct)
            if (candidate.0 ? 1 : 0, candidate.1) > (current.0 ? 1 : 0, current.1) { best[alert.key] = alert }
        }
        return order.compactMap { best[$0] }
    }

    /// The recorded period is over: its reset passed (give or take the tolerance).
    static func ended(_ record: Record, at date: Date) -> Bool {
        guard let reset = record.resetsAt else { return false }
        return date >= reset.addingTimeInterval(-samePeriodTolerance)
    }

    /// "claude|trimo|weekly_all" → "claude|trimo".
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
        "\(alert.account.label) · \(alert.account.toolName) \(alert.window.shortName) \(percent(alert.window.pct))"
    }

    /// The macOS banner for one tick's crossings.
    public static func notification(for alerts: [UsageAlert], snapshot: UsageSnapshot, threshold: Double)
        -> (title: String, subtitle: String, body: String) {
        let now = snapshot.fetchedAt
        // Where to move the work: an account of the same tool (Claude first).
        let tool = alerts.contains { $0.account.tool == "claude" } ? "claude" : alerts.first?.account.tool ?? "claude"
        let toolName = tool == "codex" ? "Codex" : "Claude"
        let advice: String
        if let room = snapshot.mostRoom(tool: tool, threshold: threshold) {
            let left = 100 - Int(snapshot.rank(room).0.rounded())
            advice = "Most room now: \(room.label) (\(left)% of the week left)."
        } else if snapshot.accounts.contains(where: { $0.tool == tool && $0.readable }) {
            advice = "No \(toolName) account is under \(percent(threshold)) right now."
        } else {
            advice = "No \(toolName) account could be read just now."
        }
        guard alerts.count == 1, let alert = alerts.first else {
            let names = alerts.map(headline).joined(separator: ", ")
            return ("\(alerts.count) limits passed \(percent(threshold))", names, advice)
        }
        let resets = until(alert.window.resetsAt, now: now).map { "resets in \($0)" }
            ?? (alert.window.pct.rounded() >= 100 ? "limit reached" : "")
        return ("\(alert.account.label): \(alert.account.toolName) \(alert.window.shortName) limit at \(percent(alert.window.pct))",
                resets, advice)
    }

    /// What one Telegram message may hold: Telegram takes 4096 UTF-16 units
    /// (after parsing, so the tags here only make this cautious).
    public static let telegramBudget = 4000
    /// Rows per table before "…and N more" (eleven accounts today).
    static let maxTableRows = 30

    /// The Telegram message (parse_mode HTML) for one tick's crossings.
    public static func telegram(for alerts: [UsageAlert], snapshot: UsageSnapshot, threshold: Double) -> String {
        let now = snapshot.fetchedAt
        let reached = alerts.contains { $0.window.pct.rounded() >= 100 }
        var blocks = [reached ? "⛔️ <b>AI usage — limit reached</b>" : "⚠️ <b>AI usage — limit almost hit</b>"]
        for alert in alerts {
            let resets = until(alert.window.resetsAt, now: now).map { " (resets in \($0))" } ?? ""
            blocks.append("• <b>\(html(alert.account.label))</b> — \(alert.account.toolName) \(html(alert.window.shortName)) at <b>\(percent(alert.window.pct))</b>\(resets)")
        }
        blocks.append("")
        return fit(blocks + summaryBlocks(snapshot, threshold: threshold))
    }

    /// `lead` (HTML), then every account's usage when there is a reading:
    /// the welcome and test messages.
    public static func telegram(lead: String, snapshot: UsageSnapshot?, threshold: Double) -> String {
        guard let snapshot else { return fit([lead]) }
        return fit([lead, ""] + summaryBlocks(snapshot, threshold: threshold))
    }

    /// Every account's usage as monospaced tables, plus the account with the
    /// most room: what the user needs in order to choose where to work next.
    public static func summary(_ snapshot: UsageSnapshot, threshold: Double) -> String {
        fit(summaryBlocks(snapshot, threshold: threshold))
    }

    /// The summary in blocks that are only ever kept or left out whole: a
    /// heading, a whole `<pre>` table, the advice line.
    static func summaryBlocks(_ snapshot: UsageSnapshot, threshold: Double) -> [String] {
        var out: [String] = []
        let claude = snapshot.accounts.filter { $0.tool == "claude" }
        if !claude.isEmpty {
            out.append("<b>Claude Code</b>")
            let rows = claude.map { account -> String in
                let cells = ["session", "weekly_all", "weekly_scoped"].map { kind in
                    account.window(kind).map { percent($0.pct) } ?? "-"
                }
                let mark = account.readable ? (account.isOver(threshold, at: snapshot.fetchedAt) ? " ⚠" : "") : " ?"
                return pad(String(account.label.prefix(15)), 16) + pad(cells[0], 6) + pad(cells[1], 6) + cells[2] + mark
            }
            out.append(table([pad("account", 16) + pad("sess", 6) + pad("week", 6) + "fable"] + capped(rows)))
        }
        let codex = snapshot.accounts.filter { $0.tool == "codex" }
        if !codex.isEmpty {
            out.append("<b>Codex</b>")
            out.append(table(capped(codex.map { pad(String($0.label.prefix(15)), 16) + ($0.binding.map { percent($0.pct) } ?? "-") })))
        }
        if let room = snapshot.mostRoom(threshold: threshold) {
            out.append("➡️ Most room now: <b>\(html(room.label))</b>")
        } else if claude.contains(where: \.readable) {
            out.append("⏳ Every Claude account is at \(percent(threshold)) or more.")
        } else if !claude.isEmpty {
            out.append("⏳ No Claude account could be read just now.")
        }
        return out
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

    /// One menu row: "trimo — week 94% · session 27%".
    public static func menuRow(_ account: UsageAccount) -> String {
        guard account.readable else { return "\(account.label) — not readable" }
        let parts = account.windows
            .filter { $0.kind != "weekly_scoped" || $0.pct > 0 }
            .sorted { $0.pct > $1.pct }
            .map { "\($0.shortName) \(percent($0.pct))" }
        return "\(account.label) — " + parts.joined(separator: " · ")
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
