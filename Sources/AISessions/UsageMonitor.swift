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

        /// The accounts whose crossings alert, in the snapshot's order.
        var covered: [UsageAccount] {
            guard let snapshot, !(scope.needsSignedIn && signedIn == nil) else { return [] }
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
            snapshot = parsed
        } catch {
            guard asked == generation else { return askAgain() }
            return report("the usage dashboard is not reachable at \(base.absoluteString)")
        }
        if loggedProblem != nil {
            Log.shared.info("usage dashboard reachable again")
            loggedProblem = nil
        }
        status = Status(snapshot: snapshot, problem: nil, signedIn: accounts.emails(),
                        scope: UsageAlertScope(config.usageAlertAccounts))
        var alerts: [UsageAlert] = []
        // Who is signed in decides whose alerts these are. Until that can be
        // read nothing is evaluated: a guess would forget the real account's
        // records (and announce them again) or announce someone else's.
        if !(status.scope.needsSignedIn && status.signedIn == nil) {
            let covered = status.covered
            let firstRun = engine.isFirstRun
            // Only covered accounts are evaluated, so the others' records go:
            // switching to an account already over the threshold is news.
            alerts = engine.evaluate(snapshot.only { account in covered.contains { $0.key == account.key } })
            if firstRun {
                let over = covered.flatMap { $0.windows.filter { $0.isOver(config.usageAlertThreshold, at: snapshot.fetchedAt) } }
                Log.shared.info("usage alerts: first reading; \(over.count) window(s) already at "
                    + "\(Int(config.usageAlertThreshold))%+ recorded without alerting")
            }
        }
        logCoverage()
        onStatus(status)
        if !alerts.isEmpty { onAlerts(alerts, snapshot) }
    }

    /// One line whenever the accounts that alert change: at launch, after a
    /// sign-in to another account, or when the address is not on the dashboard.
    private func logCoverage() {
        let labels = status.covered.map(\.label)
        let unknown = status.scope.needsSignedIn && status.signedIn == nil
        let key = unknown ? ["?"] : labels
        guard key != loggedCovered else { return }
        loggedCovered = key
        if unknown {
            let files = accounts.configDirs.map(\.path).joined(separator: ", ")
            Log.shared.warn("usage alerts: cannot tell which Claude account is signed in (\(files)); none evaluated until it can")
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
