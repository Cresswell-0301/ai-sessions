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
    }

    typealias Fetch = @Sendable (URL) async throws -> Data

    private(set) var status = Status()
    var onStatus: (Status) -> Void = { _ in }
    var onAlerts: ([UsageAlert], UsageSnapshot) -> Void = { _, _ in }

    private(set) var config: Config
    private let engine: UsageAlertEngine
    private let fetch: Fetch
    private let now: () -> Date
    private var timer: Timer?
    private var inFlight = false
    private var loggedProblem: String?

    init(config: Config, engine: UsageAlertEngine, fetch: @escaping Fetch = UsageMonitor.urlFetch,
         now: @escaping () -> Date = Date.init) {
        self.config = config
        self.engine = engine
        self.fetch = fetch
        self.now = now
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
        if new.usageAlertsEnabled != old.usageAlertsEnabled || new.usagePollSeconds != old.usagePollSeconds {
            reschedule()
        }
        if new.usageDashboardURL != old.usageDashboardURL || (new.usageAlertsEnabled && !old.usageAlertsEnabled) {
            Task { await poll() }
        }
        if !new.usageAlertsEnabled {
            status = Status()
            onStatus(status)
        }
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
        let url = base.appendingPathComponent("data.json")
        let snapshot: UsageSnapshot
        do {
            let data = try await fetch(url)
            guard let parsed = UsageSnapshot.parse(data, fetchedAt: now()) else {
                return report("the dashboard's data.json was not in the expected shape")
            }
            snapshot = parsed
        } catch {
            return report("the usage dashboard is not reachable at \(base.absoluteString)")
        }
        let firstRun = engine.isFirstRun
        let alerts = engine.evaluate(snapshot)
        if firstRun {
            let over = snapshot.accounts.flatMap { account in
                account.windows.filter { $0.pct.rounded() >= config.usageAlertThreshold }.map { _ in account.label }
            }
            Log.shared.info("usage alerts: first reading of \(snapshot.accounts.count) accounts; "
                + "\(over.count) window(s) already at \(Int(config.usageAlertThreshold))%+ recorded without alerting")
        }
        if loggedProblem != nil {
            Log.shared.info("usage dashboard reachable again")
            loggedProblem = nil
        }
        status = Status(snapshot: snapshot, problem: nil)
        onStatus(status)
        if !alerts.isEmpty { onAlerts(alerts, snapshot) }
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
