import AISessionsCore
import Foundation

/// Polls the ai-accounts dashboard's `/data.json` for usage limits and hands
/// on the windows that just crossed the alert threshold. Main-actor; only the
/// HTTP fetch runs off the main thread. The dashboard keeps the accounts'
/// tokens and refreshes them; this never talks to Anthropic or OpenAI.
@MainActor
final class UsageMonitor {
    struct Status: Equatable {
        var snapshot: UsageSnapshot?
        /// Why the latest poll failed; nil after a good one. The last good
        /// snapshot is kept meanwhile, marked by its `fetchedAt`.
        var problem: String?
        /// The Claude accounts signed in where the sessions run, by email;
        /// nil while that cannot be read.
        var signedIn: Set<String>?
        /// Whose limits alert (config `usageAlertAccounts`).
        var scope = UsageAlertScope(["current"])
        /// The dashboard's "Use first" opt-outs, read with the reading.
        var excluded: Set<String> = []

        /// The accounts whose crossings alert, in the snapshot's order. While
        /// no sign-in can be read, only the ones named in the setting.
        var covered: [UsageAccount] {
            guard let snapshot else { return [] }
            return snapshot.accounts.filter { scope.covers($0, signedIn: signedIn) }
        }

        /// Accounts the user's sessions are signed into ("in use").
        var inUse: Set<String> {
            Set(snapshot?.accounts.filter { $0.isSignedIn(signedIn) }.map(\.key) ?? [])
        }
    }

    typealias Fetch = @Sendable (URL) async throws -> Data

    private(set) var status = Status()
    var onStatus: (Status) -> Void = { _ in }
    var onAlerts: ([UsageAlert], UsageSnapshot) -> Void = { _, _ in }

    private(set) var config: Config
    private let engine: UsageAlertEngine
    private let fetch: Fetch
    private let now: () -> Date
    /// Who is signed in where the sessions run; rebuilt when the watched
    /// Claude dirs change. Tests pass their own.
    private(set) var accounts: SignedInAccounts
    private let makeAccounts: (Config) -> SignedInAccounts
    /// The covered accounts last logged, so a switch is logged once.
    private var loggedCovered: [String]?
    /// The sign-in the alerts follow, and a different one seen meanwhile
    /// with how many polls in a row saw it (see `followSignIn`).
    private var followed: Set<String>?
    private var candidate: (emails: Set<String>?, polls: Int)?
    /// The last sign-in that named an account, to tell a switch from a return.
    private var lastKnown: Set<String>?
    /// The accounts (record ids) the last poll's alerts followed.
    private var previouslyCovered = Set<String>()
    /// Each dashboard row's address as last read, for a scan that misses it.
    private var knownEmails: [String: String] = [:]
    /// Polls in a row a new sign-in must hold before the alerts follow it;
    /// losing it altogether (logged out) takes longer.
    static let switchPolls = 2
    static let lossPolls = 5
    private var timer: Timer?
    private var inFlight = false
    private var loggedProblem: String?
    /// Moves when alerts are switched or the dashboard moves: a poll that
    /// was waiting meanwhile answers for settings that no longer hold.
    private var generation = 0

    init(config: Config, engine: UsageAlertEngine, fetch: @escaping Fetch = UsageMonitor.urlFetch,
         now: @escaping () -> Date = Date.init,
         accounts makeAccounts: @escaping (Config) -> SignedInAccounts = { SignedInAccounts(configDirs: $0.claudeConfigURLs) }) {
        self.config = config
        self.engine = engine
        self.fetch = fetch
        self.now = now
        self.makeAccounts = makeAccounts
        accounts = makeAccounts(config)
        status.scope = UsageAlertScope(config.usageAlertAccounts)
        engine.threshold = config.usageAlertThreshold
    }

    var dashboardURL: URL? {
        guard let url = URL(string: config.usageDashboardURL), url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        return url
    }

    func start() {
        reschedule()
        Task { await poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func apply(_ new: Config) {
        let old = config
        config = new
        engine.threshold = new.usageAlertThreshold
        if new.usageAlertsEnabled != old.usageAlertsEnabled || new.usageDashboardURL != old.usageDashboardURL {
            generation += 1
        }
        if new.usageAlertsEnabled != old.usageAlertsEnabled || new.usagePollSeconds != old.usagePollSeconds {
            reschedule()
        }
        if new.usageDashboardURL != old.usageDashboardURL || (new.usageAlertsEnabled && !old.usageAlertsEnabled) {
            Task { await poll() }
        }
        if new.claudeConfigDirs != old.claudeConfigDirs { accounts = makeAccounts(new) }
        if !new.usageAlertsEnabled {
            status = Status()
        }
        status.scope = UsageAlertScope(new.usageAlertAccounts)
        if new != old { onStatus(status) }
    }

    private func reschedule() {
        stop()
        guard config.usageAlertsEnabled else { return }
        let timer = Timer(timeInterval: config.usagePollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.poll() }
            }
        }
        timer.tolerance = config.usagePollSeconds / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One poll: fetch, parse, decide, tell. Overlapping polls are skipped.
    func poll() async {
        guard config.usageAlertsEnabled, !inFlight else { return }
        guard let base = dashboardURL else {
            report("usageDashboardURL is not an http(s) URL: \(config.usageDashboardURL)")
            return
        }
        inFlight = true
        defer { inFlight = false }
        let asked = generation
        let url = base.appendingPathComponent("data.json")
        let snapshot: UsageSnapshot
        do {
            let data = try await fetch(url)
            guard asked == generation else { return askAgain() }
            guard let parsed = UsageSnapshot.parse(data, fetchedAt: now()) else {
                return report("the dashboard's data.json was not in the expected shape")
            }
            snapshot = withKnownEmails(parsed)
        } catch {
            guard asked == generation else { return askAgain() }
            return report("the usage dashboard is not reachable at \(base.absoluteString)")
        }
        if loggedProblem != nil {
            Log.shared.info("usage dashboard reachable again")
            loggedProblem = nil
        }
        let (signedIn, switchedTo) = followSignIn()
        status = Status(snapshot: snapshot, problem: nil, signedIn: signedIn,
                        scope: UsageAlertScope(config.usageAlertAccounts),
                        excluded: SuggestExclusions.load(from: AppPaths.expand(config.usageExcludeFile)))
        // Every account is evaluated, so each keeps its own edge; only the
        // followed ones are announced. While no sign-in can be read, the
        // accounts named in the setting still are.
        let covered = Set(status.covered.map(\.recordID))
        let firstRun = engine.isFirstRun
        // Signed in to another account: what it crossed while the alerts did
        // not follow it is news now. One followed already (scope "all", a
        // named account) keeps its records.
        if let joined = switchedTo {
            let newcomers = snapshot.accounts.filter { $0.isSignedIn(joined) && !previouslyCovered.contains($0.recordID) }
            engine.forget(Set(newcomers.map(\.recordID)))
        }
        let alerts = engine.evaluate(snapshot).filter { covered.contains($0.account.recordID) }
        previouslyCovered = covered
        if firstRun {
            let over = snapshot.accounts.flatMap { $0.windows.filter { $0.isOver(config.usageAlertThreshold, at: snapshot.fetchedAt) } }
            Log.shared.info("usage alerts: first reading; \(over.count) window(s) already at "
                + "\(Int(config.usageAlertThreshold))%+ recorded without alerting")
        }
        logCoverage()
        onStatus(status)
        if !alerts.isEmpty { onAlerts(alerts, snapshot) }
    }

    /// The sign-in the alerts follow. A different one is followed once
    /// `switchPolls` polls in a row see it (`lossPolls` when no account can be
    /// read), so the moment a login spends without an account, or a stale
    /// write of the old one, cannot swing the alerts back and forth.
    /// Returns the sign-in to follow, and the emails just switched to (a
    /// different account than the last one known; nil when there was no
    /// switch, including at launch and on coming back to the same account).
    private func followSignIn() -> (followed: Set<String>?, switchedTo: Set<String>?) {
        let seen = accounts.emails()
        var adopt = false
        if followed == nil {
            adopt = true
        } else if seen == followed {
            candidate = nil
        } else {
            let polls = candidate.map { $0.emails == seen ? $0.polls + 1 : 1 } ?? 1
            candidate = (seen, polls)
            // Losing an account (all of them, or one of several config dirs)
            // waits longer than a switch: it is how a login begins.
            let loss = seen.map { followed.map($0.isStrictSubset(of:)) ?? false } ?? true
            if polls >= (loss ? Self.lossPolls : Self.switchPolls) {
                adopt = true
                candidate = nil
            }
        }
        guard adopt else { return (followed, nil) }
        followed = seen
        guard let adopted = seen else { return (nil, nil) }
        // A switch is a known account other than the last known one.
        let previous = lastKnown
        if !adopted.isEmpty { lastKnown = adopted }
        guard let previous, !adopted.isEmpty, adopted != previous else { return (followed, nil) }
        return (followed, adopted.subtracting(previous))
    }

    /// `snapshot` with each row's address filled in from earlier readings
    /// when this scan missed it, so the row stays the same account.
    private func withKnownEmails(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        var accounts = snapshot.accounts
        for index in accounts.indices {
            let key = accounts[index].key
            if let email = accounts[index].email, !email.isEmpty {
                knownEmails[key] = email
            } else if let email = knownEmails[key] {
                accounts[index].email = email
            }
        }
        var known = snapshot
        known.accounts = accounts
        return known
    }

    /// One line whenever the accounts that alert change: at launch, after a
    /// sign-in to another account, or when the address is not on the dashboard.
    private func logCoverage() {
        let labels = status.covered.map(\.name)
        let unknown = status.scope.needsSignedIn && status.signedIn == nil
        let key = (unknown ? ["?"] : []) + labels
        guard key != loggedCovered else { return }
        loggedCovered = key
        if unknown {
            let files = accounts.configDirs.map(\.path).joined(separator: ", ")
            Log.shared.warn("usage alerts: cannot tell which Claude account is signed in (\(files)); its alerts wait for it"
                + (labels.isEmpty ? "" : "; still following " + labels.joined(separator: ", ")))
        } else if labels.isEmpty {
            let emails = (status.signedIn ?? []).sorted().joined(separator: ", ")
            Log.shared.warn("usage alerts: no dashboard account to follow" + (emails.isEmpty ? "" : " (signed in: \(emails))"))
        } else {
            Log.shared.info("usage alerts: following " + labels.joined(separator: ", "))
        }
    }

    /// This poll's answer is for settings changed while it waited (alerts
    /// switched off, another dashboard): drop it, and ask the new one.
    private func askAgain() {
        guard config.usageAlertsEnabled else { return }
        Task { await poll() }
    }

    /// Keeps the last good snapshot; logs each distinct problem once.
    private func report(_ problem: String) {
        if loggedProblem != problem {
            Log.shared.warn("usage alerts: \(problem)")
            loggedProblem = problem
        }
        status.problem = problem
        onStatus(status)
    }

    nonisolated static let urlFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
