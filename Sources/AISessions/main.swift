import AISessionsCore
import AppKit

// Entry point: no arguments runs the menu-bar app; `LaunchMode.usage` lists
// the command-line modes.
let launchMode = LaunchMode.parse(Array(CommandLine.arguments.dropFirst()))

// state/ holds titles, prompts and last messages copied out of ~/.claude,
// which is 0700: everything this process creates is owner-only, in every
// mode, and a launch repairs what older versions left world-readable.
_ = umask(0o077)
switch launchMode {
case .gui, .headless, .testNotification: AppPaths.secureStateDirectory(create: true)
case .route, .version, .help, .invalid: AppPaths.secureStateDirectory(create: false)
}

switch launchMode {
case .gui:
    MainActor.assumeIsolated { runMenuBarApp() }
case .headless(let useAppState):
    let files = HeadlessRunner.Files(useAppState: useAppState)
    // Before anything logs, config warnings included.
    Log.shared.file = files.log
    Log.shared.echo = true
    MainActor.assumeIsolated { HeadlessRunner(config: Config.load(), files: files).run() }
case .route(let query, let open):
    let status = MainActor.assumeIsolated { runRoute(query: query, open: open) }
    exit(status)
case .testNotification(let query):
    do {
        try FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true)
        try Data((query + "\n").utf8).write(to: AppDelegate.testTriggerURL, options: .atomic)
        print("asked the running app for a test notification (\(query.isEmpty ? "first listed session" : query)); "
            + "it checks every 5 s and drops a request older than \(Int(AppDelegate.testRequestMaxAge)) s")
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
    case headless(useAppState: Bool)
    case route(query: String, open: Bool)
    case testNotification(query: String)
    case version
    case help
    case invalid(String)

    static let usage = """
        usage: AISessions                       run the menu-bar app
               AISessions --headless [--use-app-state]
                                                track sessions without UI: log events and
                                                print the sessions; keeps its own state.json,
                                                snapshot.json and headless.log in
                                                state/headless/, so it can run next to the app;
                                                --use-app-state uses the app's state/ files
                                                instead (only while the app is not running)
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
        var useAppState = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            let next: LaunchMode
            switch argument {
            case "--headless": next = .headless(useAppState: false)
            case "--version": next = .version
            case "--help", "-h": next = .help
            case "--open":
                open = true
                continue
            case "--use-app-state":
                useAppState = true
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
            guard !useAppState else { return .invalid("--use-app-state only goes with --headless") }
            return .route(query: query, open: open)
        case .headless?:
            guard !open else { return .invalid("--open only goes with --route") }
            return .headless(useAppState: useAppState)
        case let other:
            guard !open else { return .invalid("--open only goes with --route") }
            guard !useAppState else { return .invalid("--use-app-state only goes with --headless") }
            return other ?? .gui
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
    // A throwaway state file and log: a look from the command line must not
    // adopt, close or catch up anything in the running app's own state, nor
    // log "first run: adopted…" into its log as if the app had lost its state.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-sessions-route-\(UUID().uuidString)", isDirectory: true)
    Log.shared.file = scratch.appendingPathComponent("route.log")
    defer {
        Log.shared.flush() // before the directory goes, or a late line recreates it
        try? FileManager.default.removeItem(at: scratch)
    }
    let engine = SessionEngine(config: Config.load(),
                               store: StateStore(url: scratch.appendingPathComponent("state.json")))
    let sessions = engine.tickNow()

    let session: TrackedSession
    switch SessionQuery.match(query, in: sessions) {
    case .found(let found):
        session = found
    case .none:
        let known = sessions.map(SessionListing.keyAndTitle).joined(separator: "\n")
        printError("no live session matches \"\(SessionListing.printable(query))\""
            + (known.isEmpty ? " (no sessions are live)" : ". Live sessions:\n\(known)"))
        return 1
    case .ambiguous(let candidates):
        printError("\"\(SessionListing.printable(query))\" matches several sessions:\n"
            + candidates.map(SessionListing.keyAndTitle).joined(separator: "\n"))
        return 1
    }

    let plan = Router.plan(for: session)
    let printable = SessionListing.printable
    print("session   \(printable(session.key.description))")
    print("title     \(printable(session.title))")
    print("state     \(SessionListing.stateLabel(session)) · \(printable(SessionListing.detail(session, now: Date())))")
    print("plan      \(printable(plan.summary))")
    if let url = plan.url { print("url       \(url.absoluteString)") }
    if let pid = plan.activatePid { print("activate  pid \(pid)") }
    if let bundle = plan.activateBundleIdentifier { print("activate  \(printable(bundle))") }
    guard open else { return 0 }

    let outcome = RouteExecutor().execute(plan, for: session.key)
    print("result    \(printable(outcome.description))")
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
/// stderr), prints the session list when it changes and keeps a snapshot
/// current. SIGINT/SIGTERM save and exit 0.
@MainActor
final class HeadlessRunner {
    /// Where a run keeps its tracker state, snapshot and log.
    struct Files: Equatable {
        var state: URL
        var snapshot: URL
        /// Nil: the app's log.
        var log: URL?

        /// Its own `state/headless/` by default: README suggests running it
        /// next to the menu-bar app, and on a shared state.json its saves
        /// would undo the app's read marks (a session read in the menu comes
        /// back unread at the next launch) or replay a turn the app already
        /// announced. `useAppState` takes the app's files, for when the app
        /// is not running.
        init(useAppState: Bool, stateDir: URL = AppPaths.stateDir) {
            if useAppState {
                state = stateDir.appendingPathComponent("state.json")
                snapshot = stateDir.appendingPathComponent("snapshot.json")
                log = nil
            } else {
                let own = stateDir.appendingPathComponent("headless", isDirectory: true)
                state = own.appendingPathComponent("state.json")
                snapshot = own.appendingPathComponent("snapshot.json")
                log = own.appendingPathComponent("headless.log")
            }
        }
    }

    private let config: Config
    private let files: Files
    private let engine: SessionEngine
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var tickInFlight = false
    private var printed: [SessionListing.Line]?

    init(config: Config, files: Files) {
        self.config = config
        self.files = files
        engine = SessionEngine(config: config, store: StateStore(url: files.state),
                               snapshot: SnapshotWriter(url: files.snapshot, delay: 0))
    }

    func run() -> Never {
        Log.shared.info("headless: home \(AppPaths.home.path), state in \(files.state.deletingLastPathComponent().path), "
            + "polling every \(config.pollIntervalSeconds)s; Ctrl-C stops")
        // --use-app-state next to the running app (in its home): say what it costs.
        if files.log == nil, AppPaths.home.standardizedFileURL == AppPaths.defaultHome.standardizedFileURL,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleIdentifier)
            .first(where: { !$0.isTerminated }) {
            Log.shared.warn("headless: the menu-bar app is running (pid \(app.processIdentifier)) on these files; "
                + "sessions read in its menu can come back unread. Without --use-app-state this run keeps its own.")
        }
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
            let printable = SessionListing.printable
            text += "  \(state) \(printable(session.key.description))  \(printable(session.title))"
                + " — \(printable(SessionListing.detail(session, now: now)))\n"
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

    /// "  claude:9eb4…  AI Track", as the listings print it.
    static func keyAndTitle(_ session: TrackedSession) -> String {
        "  \(printable(session.key.description))  \(printable(session.title))"
    }

    /// `text` without the control characters a terminal would act on.
    /// Titles come from transcripts, pasted prompts and model output, ids and
    /// projects from files and directory names (see
    /// `Formatting.withoutControlCharacters`).
    static func printable(_ text: String) -> String {
        Formatting.withoutControlCharacters(text)
    }
}
