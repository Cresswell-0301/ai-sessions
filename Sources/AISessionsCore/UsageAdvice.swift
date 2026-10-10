import Foundation

/// The dashboard's "Use first" pick, computed exactly as its page computes it
/// (`~/.ai-accounts/bin/ai-usage`, page script `recommend()` / `pickChip()`),
/// so a Telegram message names the account the dashboard names for the same
/// reading (an open page keeps the opt-outs it loaded with, and reads the
/// clock every 10 s; this reads both with each poll).
///
/// Among one tool's accounts that are fresh and not opted out on the
/// dashboard, those with at least 10% left on every window are "safe"; the
/// pick is the safe one whose weekly limit renews soonest (its quota would
/// otherwise go to waste), then the one with more left, then by name. When
/// none is safe, the pick is the one that frees up first. Pinned against the
/// page's own output on 34 cases (UsageAdviceTests).
public struct UseFirst: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        /// At least 10% left everywhere: use it now.
        case safe
        /// Every candidate is within 10% of a limit: the soonest to free up.
        case fallback
    }

    public var account: UsageAccount
    public var mode: Mode
    /// The fullest window's use and room, rounded as the page rounds.
    public var used: Int
    public var left: Int
    /// Hours until its weekly limit renews (safe) or until it frees up
    /// (fallback); nil when there is no reset time.
    public var hours: Double?

    /// The page's own words: "Use first → A · 50% left · renews in 30h", or
    /// "All near limit — B frees up in 10h".
    public var chip: String {
        let label = account.label
        switch mode {
        case .safe:
            let renews = hours.map { " · renews in " + UsageAdvice.span($0) } ?? ""
            return "Use first → \(label) · \(left)% left\(renews)"
        case .fallback:
            let frees = hours.flatMap { $0.isFinite ? "in " + UsageAdvice.span($0) : nil } ?? "later"
            return "All near limit — \(label) frees up \(frees)"
        }
    }
}

public enum UsageAdvice {
    /// A window with less room than this is "near its limit".
    public static let minLeft = 10.0

    enum Freshness: String, Equatable {
        case fresh, stale, dead, ratelimited, nodata
    }

    /// The page's `rowState`: a broken sign-in is dead, a 429 is rate
    /// limited, otherwise the age of the last reading decides (Claude: fresh
    /// under 15 min, dead from 3 h; Codex, probed hourly: 75 min and 24 h).
    static func freshness(_ account: UsageAccount, now: Date) -> Freshness {
        let error = account.error ?? ""
        if error.contains("re-login") || error.contains("invalid_grant") || error.contains("not signed in") { return .dead }
        let minutes = account.asOf.map { now.timeIntervalSince($0) / 60 }
        if error.contains("Rate Limit") { return .ratelimited }
        guard let minutes else { return .nodata }
        let (freshMax, deadMin): (Double, Double) = account.tool == "codex" ? (75, 1440) : (15, 180)
        if minutes < freshMax { return .fresh }
        return minutes >= deadMin ? .dead : .stale
    }

    /// The fullest window; the first of equal ones.
    static func binding(_ account: UsageAccount) -> UsageWindow? {
        var best: UsageWindow?
        for window in account.windows where best.map({ window.pct > $0.pct }) ?? true { best = window }
        return best
    }

    /// The window whose reset says when the account renews: its weekly
    /// limit, else (Codex, old payloads) its fullest window.
    static func renewal(_ account: UsageAccount) -> UsageWindow? {
        account.windows.first { $0.kind == "weekly_all" } ?? binding(account)
    }

    /// Hours from `now` until `date`; nil without one (or at epoch 0, as the
    /// page reads a missing reset). Negative once passed.
    static func hours(until date: Date?, now: Date) -> Double? {
        guard let date, date.timeIntervalSince1970 != 0 else { return nil }
        return date.timeIntervalSince(now) / 3600
    }

    /// The page's key into `.suggest-exclude.json`: "claude:<email>", or
    /// "claude:<label>" for a row without an email. Case-sensitive.
    public static func exclusionKey(_ account: UsageAccount) -> String {
        let id = account.email.flatMap { $0.isEmpty ? nil : $0 } ?? account.label
        return "\(account.tool):\(id)"
    }

    /// JavaScript's Math.round: halves go up.
    static func round(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }

    /// "22h" under two days, "6d" from then on; never negative.
    static func span(_ hours: Double) -> String {
        hours < 48 ? "\(max(0, round(hours)))h" : "\(round(hours / 24))d"
    }

    /// The accounts of `tool` the page would pick from, in dashboard order.
    static func candidates(_ accounts: [UsageAccount], tool: String, excluded: Set<String>,
                           now: Date) -> [(index: Int, account: UsageAccount, binding: UsageWindow)] {
        accounts.enumerated().compactMap { index, account in
            guard account.tool == tool, !excluded.contains(exclusionKey(account)),
                  freshness(account, now: now) == .fresh, let binding = binding(account) else { return nil }
            return (index, account, binding)
        }
    }

    /// The account to use first among `accounts` of `tool`; nil when no
    /// account is fresh and opted in (the page then shows no pick either).
    public static func useFirst(_ accounts: [UsageAccount], tool: String, excluded: Set<String>,
                                now: Date) -> UseFirst? {
        let eligible = candidates(accounts, tool: tool, excluded: excluded, now: now)
        guard !eligible.isEmpty else { return nil }
        let safe = eligible.filter { 100 - $0.binding.pct >= minLeft }
        if !safe.isEmpty {
            let pick = safe.min { lhs, rhs in
                let l = hours(until: renewal(lhs.account)?.resetsAt, now: now) ?? .infinity
                let r = hours(until: renewal(rhs.account)?.resetsAt, now: now) ?? .infinity
                if l != r { return l < r }
                if lhs.binding.pct != rhs.binding.pct { return lhs.binding.pct < rhs.binding.pct }
                return ordered(lhs, before: rhs)
            }!
            return UseFirst(account: pick.account, mode: .safe, used: round(pick.binding.pct),
                            left: round(100 - pick.binding.pct),
                            hours: hours(until: renewal(pick.account)?.resetsAt, now: now))
        }
        return freesUpFirst(eligible, now: now)
    }

    /// Of `accounts` of `tool` (fresh, opted in), the one whose near-limit
    /// windows free up first, safe or not: when every other account is full,
    /// when work can go on again.
    public static func freesUpFirst(_ accounts: [UsageAccount], tool: String, excluded: Set<String>, now: Date) -> UseFirst? {
        let eligible = candidates(accounts, tool: tool, excluded: excluded, now: now)
        return eligible.isEmpty ? nil : freesUpFirst(eligible, now: now)
    }

    /// The page's fallback: the account whose LAST near-limit window resets
    /// soonest, then by name.
    private static func freesUpFirst(_ eligible: [(index: Int, account: UsageAccount, binding: UsageWindow)],
                                     now: Date) -> UseFirst {
        func freesUp(_ account: UsageAccount) -> Double {
            account.windows.filter { 100 - $0.pct < minLeft }
                .map { hours(until: $0.resetsAt, now: now) ?? .infinity }
                .max() ?? .infinity
        }
        let pick = eligible.min { lhs, rhs in
            let l = freesUp(lhs.account), r = freesUp(rhs.account)
            if l != r { return l < r }
            return ordered(lhs, before: rhs)
        }!
        return UseFirst(account: pick.account, mode: .fallback, used: round(pick.binding.pct),
                        left: round(100 - pick.binding.pct), hours: freesUp(pick.account))
    }

    /// By label as a person reads it ("alpha" before "Beta"), then dashboard order.
    private static func ordered(_ lhs: (index: Int, account: UsageAccount, binding: UsageWindow),
                                before rhs: (index: Int, account: UsageAccount, binding: UsageWindow)) -> Bool {
        switch lhs.account.label.localizedCompare(rhs.account.label) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.index < rhs.index
        }
    }

    /// The account of `tool` with the most room now: among the same
    /// candidates as `useFirst` (fresh, opted in), the most left on its
    /// fullest window, then the less-used week, then by name.
    public static func mostLeft(_ accounts: [UsageAccount], tool: String, excluded: Set<String>,
                                now: Date) -> (account: UsageAccount, left: Int)? {
        let eligible = candidates(accounts, tool: tool, excluded: excluded, now: now)
        func weekly(_ account: UsageAccount) -> Double { renewal(account)?.used(at: now) ?? 0 }
        let pick = eligible.min { lhs, rhs in
            if lhs.binding.pct != rhs.binding.pct { return lhs.binding.pct < rhs.binding.pct }
            let l = weekly(lhs.account), r = weekly(rhs.account)
            if l != r { return l < r }
            return ordered(lhs, before: rhs)
        }
        return pick.map { ($0.account, round(100 - $0.binding.pct)) }
    }
}

/// The dashboard's opt-outs from its "Use first" pick: `~/.ai-accounts/
/// .suggest-exclude.json`, a JSON array of keys such as
/// "claude:finance.nexxa@gmail.com". Read as the dashboard reads it: anything
/// unreadable (missing, half-written) means nothing is excluded.
public enum SuggestExclusions {
    public static func load(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let keys = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return Set(keys.compactMap { $0 as? String })
    }
}
