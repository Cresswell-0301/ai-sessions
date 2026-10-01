import AISessionsCore
import AppKit

/// The system calls a route needs; tests substitute a recorder.
@MainActor
protocol RouteActions {
    func open(_ url: URL) -> Bool
    func activate(pid: Int32) -> Bool
    func activate(bundleIdentifier: String) -> Bool
}

/// What carrying out a plan did.
enum RouteOutcome: Equatable, CustomStringConvertible {
    case openedURL(URL)
    case activatedProcess(Int32)
    case activatedApp(String)
    case failed(String)

    var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }

    var description: String {
        switch self {
        case .openedURL(let url): return "opened \(url.absoluteString)"
        case .activatedProcess(let pid): return "activated pid \(pid)"
        case .activatedApp(let bundle): return "activated \(bundle)"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

/// Carries out a `RoutePlan`: the deep link first; the app to activate when
/// there is no link or it could not be opened.
@MainActor
struct RouteExecutor {
    var actions: RouteActions = WorkspaceRouteActions()

    @discardableResult
    func execute(_ plan: RoutePlan, for key: SessionKey) -> RouteOutcome {
        let outcome = attempt(plan)
        let line = "route \(key): \(plan.summary) -> \(outcome)"
        if outcome.succeeded { Log.shared.info(line) } else { Log.shared.warn(line) }
        return outcome
    }

    func attempt(_ plan: RoutePlan) -> RouteOutcome {
        var problems: [String] = []
        if let url = plan.url {
            if actions.open(url) { return .openedURL(url) }
            problems.append("could not open \(url.absoluteString)")
        }
        if let pid = plan.activatePid {
            if actions.activate(pid: pid) { return .activatedProcess(pid) }
            problems.append("could not activate pid \(pid)")
        }
        if let bundle = plan.activateBundleIdentifier {
            if actions.activate(bundleIdentifier: bundle) { return .activatedApp(bundle) }
            problems.append("could not activate \(bundle)")
        }
        return .failed(problems.isEmpty ? "nothing to open or activate" : problems.joined(separator: "; "))
    }
}

/// The real thing: LaunchServices and NSRunningApplication.
@MainActor
struct WorkspaceRouteActions: RouteActions {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func activate(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return activate(app)
    }

    func activate(bundleIdentifier: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated }) {
            return activate(app)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.shared.warn("could not launch \(bundleIdentifier): \(error.localizedDescription)") }
        }
        return true
    }

    /// Activation is cooperative since macOS 14: hand our activation to the
    /// target, then ask in our name; the plain request covers the case where
    /// we were not active and had nothing to hand over.
    private func activate(_ app: NSRunningApplication) -> Bool {
        NSApp?.yieldActivation(to: app)
        return app.activate(from: .current, options: []) || app.activate(options: [])
    }
}
