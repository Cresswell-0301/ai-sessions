import AISessionsCore
import AppKit

// Entry point: no arguments runs the menu-bar app; `LaunchMode.usage` lists
// the command-line modes.
switch LaunchMode.parse(Array(CommandLine.arguments.dropFirst())) {
case .gui:
    MainActor.assumeIsolated { runMenuBarApp() }
case .headless:
    Log.shared.echo = true // before anything logs, config warnings included
    MainActor.assumeIsolated { HeadlessRunner(config: Config.load()).run() }
case .route(let query, let open):
    let status = MainActor.assumeIsolated { runRoute(query: query, open: open) }
    Log.shared.flush()
    exit(status)
case .testNotification(let query):
    do {
        try FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true)
        try Data((query + "\n").utf8).write(to: AppDelegate.testTriggerURL, options: .atomic)
        print("asked the running app for a test notification (\(query.isEmpty ? "first listed session" : query)); it checks every 5 s")
    } catch {
        FileHandle.standardError.write(Data("could not write \(AppDelegate.testTriggerURL.path): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
case .version:
    print("\(AppInfo.name) \(AppInfo.version)")
case .help:
    print(LaunchMode.usage)
case .invalid(let problem):
    FileHandle.standardError.write(Data("\(problem)\n\n\(LaunchMode.usage)\n".utf8))
    exit(64) // EX_USAGE
}

enum AppInfo {
    static let name = "AI Sessions"
    static let bundleIdentifier = "local.ai-sessions.menubar"
    /// Kept equal to CFBundleShortVersionString in Resources/Info.plist; the
    /// binary also runs outside the bundle, where there is no Info.plist.
    static let version = "1.0.0"
}

/// What the command line asks for.
enum LaunchMode: Equatable {
    case gui
    case headless
    case route(query: String, open: Bool)
    case testNotification(query: String)
    case version
    case help
    case invalid(String)

    static let usage = """
        usage: AISessions                       run the menu-bar app
               AISessions --headless            track sessions without UI: log events,
                                                print the sessions, write state/snapshot.json
               AISessions --route <key> [--open]
                                                print the route back to a session (a key such as
                                                claude:<uuid> or a unique prefix of one);
                                                --open also takes it
               AISessions --test-notification [<key>]
                                                ask the running app to post a sample notification
                                                for a session (default: the first listed one)
               AISessions --version
        """

    static func parse(_ arguments: [String]) -> LaunchMode {
        var mode: LaunchMode?
        var open = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            let next: LaunchMode
            switch argument {
            case "--headless": next = .headless
            case "--version": next = .version
            case "--help", "-h": next = .help
            case "--open":
                open = true
                continue
            case "--test-notification":
                var query = ""
                if let next = rest.first, !next.hasPrefix("-") { query = next; rest = rest.dropFirst() }
                next = .testNotification(query: query)
            case "--route":
                guard let query = rest.popFirst(), !query.hasPrefix("-") else {
                    return .invalid("--route needs a session key, e.g. claude:<uuid>")
                }
                next = .route(query: query, open: false)
            default:
                // Finder and older launch paths may add a process serial number.
                if argument.hasPrefix("-psn_") { continue }
                return .invalid("unknown argument: \(argument)")
            }
            guard mode == nil else { return .invalid("choose one of --headless, --route, --test-notification, --version") }
            mode = next
        }
        switch mode {
        case .route(let query, _)?:
            return .route(query: query, open: open)
        case let other?:
            return open ? .invalid("--open only goes with --route") : other
        case nil:
            return open ? .invalid("--open only goes with --route") : .gui
        }
    }
}

// MARK: - Menu-bar app

@MainActor
func runMenuBarApp() -> Never {
    if let other = otherInstance() {
        Log.shared.info("another \(AppInfo.name) is already running (pid \(other.processIdentifier)); exiting")
        Log.shared.flush()
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate // weak: the extended lifetime below keeps it alive
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
}

/// Another running process of this bundle. Outside a bundle (a dev build)
/// there is no identity to compare, so every copy runs.
@MainActor
private func otherInstance() -> NSRunningApplication? {
    guard let id = Bundle.main.bundleIdentifier else { return nil }
    let me = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .first { $0.processIdentifier != me && !$0.isTerminated }
}

// MARK: - --route

/// Prints the plan for one session and, with `open`, carries it out.
/// Returns the process exit status.
@MainActor
func runRoute(query: String, open: Bool) -> Int32 {
    // A throwaway state file: a look from the command line must not adopt,
    // close or catch up anything in the running app's own state.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-sessions-route-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let engine = SessionEngine(config: Config.load(),
                               store: StateStore(url: scratch.appendingPathComponent("state.json")))
    let sessions = engine.tickNow()

    let session: TrackedSession
    switch SessionQuery.match(query, in: sessions) {
    case .found(let found):
        session = found
    case .none:
        let known = sessions.map { "  \($0.key)  \($0.title)" }.joined(separator: "\n")
        printError("no live session matches \"\(query)\""
            + (known.isEmpty ? " (no sessions are live)" : ". Live sessions:\n\(known)"))
        return 1
    case .ambiguous(let candidates):
        printError("\"\(query)\" matches several sessions:\n"
            + candidates.map { "  \($0.key)  \($0.title)" }.joined(separator: "\n"))
        return 1
    }

    let plan = Router.plan(for: session)
    print("session   \(session.key)")
    print("title     \(session.title)")
    print("state     \(SessionListing.stateLabel(session)) · \(SessionListing.detail(session, now: Date()))")
    print("plan      \(plan.summary)")
    if let url = plan.url { print("url       \(url.absoluteString)") }
    if let pid = plan.activatePid { print("activate  pid \(pid)") }
    if let bundle = plan.activateBundleIdentifier { print("activate  \(bundle)") }
    guard open else { return 0 }

    let outcome = RouteExecutor().execute(plan, for: session.key)
    print("result    \(outcome)")
    return outcome.succeeded ? 0 : 1
}

/// Resolves the `--route` argument: an exact key, else a unique prefix of a
/// key ("claude:9eb4") or of a bare id ("9eb4895f").
enum SessionQuery {
    enum Match: Equatable {
        case found(TrackedSession)
        case none
        case ambiguous([TrackedSession])
    }

    static func match(_ query: String, in sessions: [TrackedSession]) -> Match {
        if let exact = sessions.first(where: { $0.key.description == query }) { return .found(exact) }
        let hits = sessions.filter { $0.key.description.hasPrefix(query) || $0.key.id.hasPrefix(query) }
        switch hits.count {
        case 0: return .none
        case 1: return .found(hits[0])
        default: return .ambiguous(hits)
        }
    }
}

private func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - --headless

/// The engine without UI: ticks on a timer, logs every event (echoed to
/// stderr), prints the session list when it changes and keeps
/// `state/snapshot.json` current. SIGINT/SIGTERM save and exit 0.
@MainActor
final class HeadlessRunner {
    private let config: Config
    private let engine: SessionEngine
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var tickInFlight = false
    private var printed: [SessionListing.Line]?

    init(config: Config) {
        self.config = config
        engine = SessionEngine(config: config, store: .standard(),
                               snapshot: SnapshotWriter(url: SnapshotWriter.standardURL, delay: 0))
    }

    func run() -> Never {
        Log.shared.info("headless: home \(AppPaths.home.path), polling every \(config.pollIntervalSeconds)s; Ctrl-C stops")
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN) // delivered through the dispatch source instead
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [unowned self] in
                MainActor.assumeIsolated { self.stop(signalNumber) }
            }
            source.resume()
            signalSources.append(source)
        }
        let timer = Timer(timeInterval: config.pollIntervalSeconds, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { self.tick() }
        }
        timer.tolerance = config.pollIntervalSeconds / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
        // The main run loop, not dispatchMain(): that one retires the main
        // thread and drains the main queue on pool threads, which breaks
        // every main-actor assumption above. The repeating timer keeps the
        // loop from ever running out of sources.
        RunLoop.main.run()
        exit(0)
    }

    private func tick() {
        guard !tickInFlight else { return }
        tickInFlight = true
        engine.tick { [unowned self] update in
            tickInFlight = false
            printIfChanged(update.sessions)
        }
    }

    /// Prints when a session appears, goes, or changes state, title or read
    /// state; not when only its age or last message moved.
    private func printIfChanged(_ sessions: [TrackedSession]) {
        let lines = sessions.map(SessionListing.Line.init)
        guard lines != printed else { return }
        printed = lines
        let now = Date()
        var text = "\(sessions.count) session\(sessions.count == 1 ? "" : "s")\n"
        for session in sessions {
            let state = SessionListing.stateLabel(session).padding(toLength: 8, withPad: " ", startingAt: 0)
            text += "  \(state) \(session.key)  \(session.title) — \(SessionListing.detail(session, now: now))\n"
        }
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func stop(_ signalNumber: Int32) -> Never {
        timer?.invalidate()
        engine.shutdown()
        Log.shared.info("headless: stopped by \(signalNumber == SIGINT ? "SIGINT" : "SIGTERM")")
        Log.shared.flush()
        exit(0)
    }
}

/// Plain-text descriptions shared by `--headless` and `--route`.
enum SessionListing {
    /// The fields whose change is worth a new listing.
    struct Line: Equatable {
        let key: SessionKey
        let state: ActivityState
        let unread: Bool
        let title: String
        let project: String

        init(_ session: TrackedSession) {
            key = session.key
            state = session.state
            unread = session.unread
            title = session.title
            project = session.project
        }
    }

    /// "waiting", "unread" (finished, not yet seen), "running" or "idle".
    static func stateLabel(_ session: TrackedSession) -> String {
        if session.state != .waiting && session.unread { return "unread" }
        return session.state.rawValue
    }

    static func detail(_ session: TrackedSession, now: Date) -> String {
        MenuRowText.detail(for: session, now: now)
    }
}
