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

    public init(kind: String, label: String, pct: Double, resetsAt: Date? = nil) {
        self.kind = kind
        self.label = label
        self.pct = pct
        self.resetsAt = resetsAt
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
    /// "resets"}]}}], "meta": {…}}`. Rows it skipped (excluded, broken) and
    /// windows without a number are left out; nil if the shape is not that.
    public static func parse(_ data: Data, fetchedAt: Date) -> UsageSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["rows"] as? [Any] else { return nil }
        var accounts: [UsageAccount] = []
        for case let row as [String: Any] in rows {
            guard let tool = row["tool"] as? String, let label = row["label"] as? String,
                  row["skipped"] as? Bool != true else { continue }
            let limits = row["limits"] as? [String: Any] ?? [:]
            var windows: [UsageWindow] = []
            for case let window as [String: Any] in limits["windows"] as? [Any] ?? [] {
                guard let kind = window["kind"] as? String, let pct = (window["pct"] as? NSNumber)?.doubleValue,
                      pct.isFinite else { continue }
                let resets = (window["resets"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(UsageWindow(kind: kind, label: window["label"] as? String ?? kind,
                                           pct: pct, resetsAt: resets))
            }
            let error = limits["error"] as? String
            let readable = (error?.isEmpty ?? true) && !windows.isEmpty
            accounts.append(UsageAccount(tool: tool, label: label, windows: windows, readable: readable))
        }
        return UsageSnapshot(accounts: accounts, fetchedAt: fetchedAt)
    }

    /// The Claude account with the most room left now: every window under the
    /// threshold, then the lowest weekly, then the lowest session use.
    public func mostRoom(tool: String = "claude", threshold: Double) -> UsageAccount? {
        accounts
            .filter { $0.tool == tool && $0.readable && $0.windows.allSatisfy { $0.pct.rounded() < threshold } }
            .min { lhs, rhs in
                let l = (lhs.window("weekly_all")?.pct ?? lhs.binding?.pct ?? 0, lhs.window("session")?.pct ?? 0)
                let r = (rhs.window("weekly_all")?.pct ?? rhs.binding?.pct ?? 0, rhs.window("session")?.pct ?? 0)
                return l < r
            }
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
    public var key: String { "\(account.tool)|\(account.label)|\(window.kind)" }
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
    public func evaluate(_ snapshot: UsageSnapshot) -> [UsageAlert] {
        let announce = state.initialized
        var alerts: [UsageAlert] = []
        var next = state
        for account in snapshot.accounts where account.readable {
            for window in account.windows {
                let alert = UsageAlert(account: account, window: window)
                guard window.pct.rounded() >= threshold else {
                    next.alerted[alert.key] = nil // dropped below: armed again
                    continue
                }
                if let record = next.alerted[alert.key], Self.samePeriod(record.resetsAt, window.resetsAt) { continue }
                next.alerted[alert.key] = Record(resetsAt: window.resetsAt, pct: window.pct, alertedAt: now())
                if announce { alerts.append(alert) }
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
    /// "2d 4h", "3h 10m", "45m".
    public static func until(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
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
        let room = snapshot.mostRoom(threshold: threshold)
        let advice = room.map { account -> String in
            let left = 100 - Int((account.window("weekly_all")?.pct ?? account.binding?.pct ?? 0).rounded())
            return "Most room now: \(account.label) (\(left)% of the week left)."
        } ?? "No Claude account is under \(percent(threshold)) right now."
        guard alerts.count == 1, let alert = alerts.first else {
            let names = alerts.map(headline).joined(separator: ", ")
            return ("\(alerts.count) limits passed \(percent(threshold))", names, advice)
        }
        let resets = until(alert.window.resetsAt, now: now).map { "resets in \($0)" } ?? "usage limit"
        return ("\(alert.account.label): \(alert.account.toolName) \(alert.window.shortName) limit at \(percent(alert.window.pct))",
                resets, advice)
    }

    /// The Telegram message (parse_mode HTML) for one tick's crossings.
    public static func telegram(for alerts: [UsageAlert], snapshot: UsageSnapshot, threshold: Double) -> String {
        let now = snapshot.fetchedAt
        var lines = ["⚠️ <b>AI usage — limit almost hit</b>"]
        for alert in alerts {
            let resets = until(alert.window.resetsAt, now: now).map { " (resets in \($0))" } ?? ""
            lines.append("• <b>\(html(alert.account.label))</b> — \(alert.account.toolName) \(html(alert.window.shortName)) at <b>\(percent(alert.window.pct))</b>\(resets)")
        }
        lines.append("")
        lines.append(summary(snapshot, threshold: threshold))
        return lines.joined(separator: "\n")
    }

    /// Every account's usage as monospaced tables, plus the account with the
    /// most room: what the user needs in order to choose where to work next.
    public static func summary(_ snapshot: UsageSnapshot, threshold: Double) -> String {
        var out: [String] = []
        let claude = snapshot.accounts.filter { $0.tool == "claude" }
        if !claude.isEmpty {
            out.append("<b>Claude Code</b>")
            var table = [pad("account", 16) + pad("sess", 6) + pad("week", 6) + "fable"]
            for account in claude {
                let cells = ["session", "weekly_all", "weekly_scoped"].map { kind in
                    account.window(kind).map { percent($0.pct) } ?? "-"
                }
                let mark = account.readable ? (account.windows.contains { $0.pct.rounded() >= threshold } ? " ⚠" : "") : " ?"
                table.append(pad(String(account.label.prefix(15)), 16) + pad(cells[0], 6) + pad(cells[1], 6) + cells[2] + mark)
            }
            out.append("<pre>" + html(table.joined(separator: "\n")) + "</pre>")
        }
        let codex = snapshot.accounts.filter { $0.tool == "codex" }
        if !codex.isEmpty {
            out.append("<b>Codex</b>")
            let table = codex.map { pad(String($0.label.prefix(15)), 16) + ($0.binding.map { percent($0.pct) } ?? "-") }
            out.append("<pre>" + html(table.joined(separator: "\n")) + "</pre>")
        }
        if let room = snapshot.mostRoom(threshold: threshold) {
            out.append("➡️ Most room now: <b>\(html(room.label))</b>")
        } else if !claude.isEmpty {
            out.append("⏳ Every Claude account is at \(percent(threshold)) or more.")
        }
        return out.joined(separator: "\n")
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
