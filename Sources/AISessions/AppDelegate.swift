import AISessionsCore
import AppKit
import Darwin
import UserNotifications

/// The menu-bar app: ticks the engine, feeds the status item and the
/// notifier, and turns their clicks into routes and read marks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// config.json and the pause flag are looked at this often.
    static let housekeepingInterval: TimeInterval = 5
    /// Coalesces snapshot.json writes; the file is for other tools, not the UI.
    static let snapshotDelay: TimeInterval = 2
    /// A test-notification request older than this was left while the app
    /// was not running; it is dropped rather than posted at a later launch.
    nonisolated static let testRequestMaxAge: TimeInterval = 60

    private(set) var config: Config
    /// Set while config.json cannot be used; the menu shows it.
    private(set) var configProblem: ConfigProblem?
    private let engine: SessionEngine
    private var configWatcher = ConfigWatcher(url: AppPaths.home.appendingPathComponent("config.json"))
    private let pauseFlag = PauseFlag.standard
    private var paused: Bool
    /// Nil outside an .app bundle. Tests install one over a recording center.
    private(set) var notifier: Notifier?
    /// Takes the route back to a session. Tests substitute a recorder, so
    /// nothing is opened or activated.
    var route: @MainActor (TrackedSession) -> Void = AppDelegate.takeRoute
    private var statusMenu: StatusMenuController?
    private var timer: Timer?
    private(set) var tickInFlight = false
    private var lastHousekeeping = Date()
    private var housekeepingRounds = 0
    private(set) var sessions: [TrackedSession] = []
    /// Last view of every session seen this run, so a click on the
    /// notification of a session that has since ended can still route.
    private var lastKnown: [SessionKey: TrackedSession] = [:]
    /// The first tick has been delivered: `sessions` is the live list.
    private var hasDelivered = false
    /// Clicks that came before that, the one that launched the app among
    /// them. Routed right after the first delivery, so they use the live
    /// session's host and pid (the window id comes from them) and not the
    /// placeholder's, which sends Claude's link to the last active window.
    private var pendingOpens: [(key: SessionKey, markingRead: Bool)] = []
    private var activity: NSObjectProtocol?

    override convenience init() {
        self.init { config in
            SessionEngine(config: config, store: .standard(),
                          snapshot: SnapshotWriter(url: SnapshotWriter.standardURL, delay: Self.snapshotDelay))
        }
    }

    /// `makeEngine` builds the engine for the loaded config; tests pass one
    /// over fake sources and a scratch store.
    init(makeEngine: (Config) -> SessionEngine) {
        let launch = Config.launch()
        config = launch.config
        switch launch.file {
        case .valid(_, let data): Config.rememberLastGood(data)
        case .missing: Config.forgetLastGood()
        case .invalid(let reason): configProblem = ConfigProblem(reason: reason, usingDefaults: !launch.usedLastGood)
        }
        engine = makeEngine(launch.config)
        paused = pauseFlag.isPaused
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The delegate must be in place before launch finishes, or the click
        // that launched the app is lost. Outside a bundle the notification
        // center raises an exception, so a dev build runs without it.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Log.shared.warn("not running from an .app bundle (\(Bundle.main.bundleURL.path)); notifications are off")
            return
        }
        install(Notifier(center: UNUserNotificationCenter.current()))
    }

    /// Wires the notifier's clicks and permission reports to the app.
    func install(_ notifier: Notifier) {
        notifier.onOpen = { [weak self] key, markingRead in self?.open(key, markingRead: markingRead) }
        notifier.onMarkRead = { [weak self] key in self?.markRead(key) }
        notifier.onPermissionChange = { [weak self] permission in
            self?.statusMenu?.setNotificationPermission(permission)
        }
        self.notifier = notifier
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without windows the app counts as invisible, and App Nap would
        // stretch the 1 s poll into delays of many seconds.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching AI sessions for finished turns")
        statusMenu = StatusMenuController(actions: .init(
            open: { [weak self] key in self?.open(key) },
            markRead: { [weak self] key in self?.markRead(key) },
            markAllRead: { [weak self] in self?.markAllRead() },
            togglePause: { [weak self] in self?.togglePause() },
            sendTestNotification: { [weak self] in self?.sendTestNotification(query: "") }
        ))
        statusMenu?.update(sessions: [], paused: paused)
        statusMenu?.setConfigProblem(configProblem)
        notifier?.requestAuthorization()
        Log.shared.info("\(AppInfo.name) \(AppInfo.version) started (pid \(getpid())); home \(AppPaths.home.path)"
            + (paused ? "; notifications paused" : ""))
        scheduleTimer()
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        engine.shutdown()
        Log.shared.info("\(AppInfo.name) stopped")
        Log.shared.flush()
    }

    // MARK: Ticking

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = config.pollIntervalSeconds
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 10
        // .common: keep ticking while the menu is open (event-tracking mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick() {
        housekeepIfDue()
        guard !tickInFlight else { return }
        tickInFlight = true
        engine.tick { [weak self] update in self?.deliver(update) }
    }

    /// One tick's result, on the main queue.
    func deliver(_ update: SessionEngine.Update) {
        tickInFlight = false
        if let notifier {
            let posted = notifier.handle(update.events, config: config, paused: paused)
            notifier.withdraw(Self.staleBanners(before: sessions, after: update.sessions, posted: posted))
        }
        show(update.sessions)
        guard !hasDelivered else { return }
        hasDelivered = true
        // Banners left from before a restart for sessions read since.
        notifier?.removeDelivered(keeping: Set(update.sessions.filter(\.unread).map(\.key)))
        let queued = pendingOpens
        pendingOpens = []
        for click in queued { open(click.key, markingRead: click.markingRead) }
    }

    /// Banners of sessions that needed you in the last delivered list and,
    /// still listed, no longer do, though no event said so: a question
    /// answered in the editor (waiting → idle), a turn stopped or abandoned.
    /// What was posted this tick is current whatever the list says. A session
    /// that left the list keeps its banner (see `Notifier.handle`, `.ended`).
    static func staleBanners(before: [TrackedSession], after: [TrackedSession],
                             posted: Set<SessionKey>) -> [SessionKey] {
        let needed = Set(before.lazy.filter(\.needsAttention).map(\.key))
        guard !needed.isEmpty else { return [] }
        return after.filter { needed.contains($0.key) && !$0.needsAttention && !posted.contains($0.key) }.map(\.key)
    }

    private func show(_ sessions: [TrackedSession]) {
        self.sessions = sessions
        for session in sessions { lastKnown[session.key] = session }
        if lastKnown.count > 500 {
            let keep = Set(lastKnown.values.sorted { $0.lastChange > $1.lastChange }.prefix(250).map(\.key))
            lastKnown = lastKnown.filter { keep.contains($0.key) }
        }
        statusMenu?.update(sessions: sessions, paused: paused)
    }

    func housekeepIfDue(now: Date = Date()) {
        guard abs(now.timeIntervalSince(lastHousekeeping)) >= Self.housekeepingInterval else { return }
        lastHousekeeping = now
        // Turning notifications on in System Settings must clear the fix-it row.
        housekeepingRounds += 1
        if housekeepingRounds % 6 == 0 { notifier?.refreshPermission() }
        // `echo <key> > state/test-notification` (or --test-notification) asks
        // the running app for a sample banner through its own notifier.
        switch Self.takeTestRequest(at: Self.testTriggerURL, now: now) {
        case .fresh(let query)?:
            sendTestNotification(query: query)
        case .stale(let age)?:
            Log.shared.info("test notification: dropped a request left \(Formatting.duration(age)) ago")
        case nil:
            break
        }
        if configWatcher.checkForChange() { reloadConfig() }
        // The flag is a file so that a script can pause notifications too.
        let filePaused = pauseFlag.isPaused
        if filePaused != paused {
            paused = filePaused
            Log.shared.info("notifications \(paused ? "paused" : "resumed") (\(pauseFlag.url.lastPathComponent))")
            statusMenu?.update(sessions: sessions, paused: paused)
        }
    }

    /// Runs once per change of the file's stamp, so a broken file is logged
    /// once, not every 5 s.
    private func reloadConfig() {
        let environment = ProcessInfo.processInfo.environment
        switch Config.read() {
        case .invalid(let reason):
            // A comment, a half-typed value, an unclosed brace: keep what runs.
            // The defaults would turn the notifications and sound the user
            // turned off back on, and drop their watched dirs.
            Log.shared.warn("config.json has an error (\(reason)); keeping the settings in use")
            setConfigProblem(ConfigProblem(reason: reason, usingDefaults: configProblem?.usingDefaults ?? false))
        case .missing:
            Config.forgetLastGood()
            setConfigProblem(nil)
            apply(Config().overridden(by: environment))
        case .valid(let new, let data):
            Config.rememberLastGood(data)
            setConfigProblem(nil)
            apply(new.overridden(by: environment))
        }
    }

    private func apply(_ new: Config) {
        guard new != config else { return }
        let old = config
        config = new
        Log.shared.info("config.json changed; reloaded")
        engine.apply(new)
        if new.pollIntervalSeconds != old.pollIntervalSeconds { scheduleTimer() }
    }

    private func setConfigProblem(_ problem: ConfigProblem?) {
        guard problem != configProblem else { return }
        configProblem = problem
        statusMenu?.setConfigProblem(problem)
    }

    // MARK: Actions

    /// Back to the session (menu row or notification), which also reads it
    /// unless the click came from a sample banner.
    func open(_ key: SessionKey, markingRead: Bool = true) {
        guard hasDelivered else {
            pendingOpens.append((key, markingRead))
            return
        }
        if markingRead { markRead(key) }
        // An ended session (tab closed, app restarted since the banner) still
        // routes: its deep link reopens the conversation in the editor.
        route(sessions.first { $0.key == key } ?? lastKnown[key] ?? Self.placeholder(for: key))
    }

    /// Plans the route and takes it. Planning reads process tables and
    /// editor logs: keep it off the main thread.
    static func takeRoute(_ session: TrackedSession) {
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = Router.plan(for: session)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = RouteExecutor().execute(plan, for: session.key) }
            }
        }
    }

    /// Stand-in for a session this run never saw: every session on this Mac
    /// lives in a VS Code window, so plan a deep link to the last active one.
    static func placeholder(for key: SessionKey) -> TrackedSession {
        let now = Date()
        return TrackedSession(key: key, title: key.description, project: "", state: .idle,
                              entrypoint: key.agent == .codex ? "codex_vscode" : "claude-vscode",
                              host: .vscode(extensionHostPid: nil), firstSeen: now, lastChange: now)
    }

    private func markRead(_ key: SessionKey) {
        notifier?.withdraw([key])
        engine.markRead(key) { [weak self] sessions in self?.show(sessions) }
    }

    private func markAllRead() {
        notifier?.withdrawAll()
        engine.markAllRead { [weak self] sessions in self?.show(sessions) }
    }

    nonisolated static var testTriggerURL: URL { AppPaths.stateDir.appendingPathComponent("test-notification") }

    enum TestRequest: Equatable {
        case fresh(query: String)
        case stale(age: TimeInterval)
    }

    /// Reads and removes the request at `url`, if any. One written more than
    /// `testRequestMaxAge` from `now` (by the file's date) was left while the
    /// app was not running: a sample banner popping up at a later launch,
    /// maybe days later, would only puzzle.
    nonisolated static func takeTestRequest(at url: URL, now: Date) -> TestRequest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        try? FileManager.default.removeItem(at: url)
        let age = written.map { now.timeIntervalSince($0) } ?? 0
        guard abs(age) <= testRequestMaxAge else { return .stale(age: age) }
        return .fresh(query: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// An empty query means the first listed session.
    func sendTestNotification(query: String) {
        guard let notifier else {
            Log.shared.warn("test notification: notifications are unavailable outside the .app bundle")
            return
        }
        let session: TrackedSession?
        if query.isEmpty {
            session = sessions.first
        } else if case .found(let found) = SessionQuery.match(query, in: sessions) {
            session = found
        } else {
            session = nil
        }
        guard let session else {
            Log.shared.warn("test notification: no listed session matches \"\(query)\"")
            return
        }
        notifier.refreshPermission()
        notifier.postTest(for: session, sound: config.sound)
    }

    private func togglePause() {
        do {
            try pauseFlag.set(!paused)
            paused.toggle()
            Log.shared.info("notifications \(paused ? "paused" : "resumed") from the menu")
        } catch {
            Log.shared.error("could not \(paused ? "resume" : "pause") notifications: \(error.localizedDescription)")
        }
        statusMenu?.update(sessions: sessions, paused: paused)
    }
}

// MARK: - Engine

/// The sources and the tracker, confined to one serial queue (DESIGN.md
/// "Threading"). Callers get immutable snapshots back on the main queue.
final class SessionEngine: @unchecked Sendable {
    struct Update: Sendable {
        /// The visible sessions, in display order.
        var sessions: [TrackedSession]
        var events: [TrackerEvent]
    }

    private let queue = DispatchQueue(label: "ai-sessions.engine", qos: .utility)
    private let store: StateStore
    private let snapshot: SnapshotWriter?
    private let makeSources: (Config) -> [SessionSource]
    private var config: Config
    private var tracker: Tracker

    /// `makeSources` is for tests (fake sources); the app reads the
    /// configured Claude dirs and Codex homes.
    init(config: Config, store: StateStore, snapshot: SnapshotWriter? = nil,
         makeSources: @escaping (Config) -> [SessionSource] = SessionEngine.makeSources(for:)) {
        self.config = config
        self.store = store
        self.snapshot = snapshot
        self.makeSources = makeSources
        tracker = Tracker(sources: makeSources(config), store: store, config: config)
    }

    /// One tick on the engine queue; `deliver` runs on the main queue.
    func tick(deliver: @escaping @MainActor (Update) -> Void) {
        queue.async { [self] in
            let update = tickOnQueue()
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(update) } }
        }
    }

    /// A synchronous tick for one-shot commands: every tracked session,
    /// automation included.
    func tickNow() -> [TrackedSession] {
        queue.sync {
            _ = tickOnQueue()
            return tracker.allSessions
        }
    }

    func markRead(_ key: SessionKey, deliver: @escaping @MainActor ([TrackedSession]) -> Void) {
        queue.async { [self] in
            tracker.markRead(key)
            publish(deliver)
        }
    }

    func markAllRead(deliver: @escaping @MainActor ([TrackedSession]) -> Void) {
        queue.async { [self] in
            tracker.markAllRead()
            publish(deliver)
        }
    }

    /// Settings take effect from the next tick. New Claude dirs or Codex
    /// homes need new sources, hence a new tracker; it keeps the same store,
    /// so it restores every session as a restarted app would.
    func apply(_ new: Config) {
        queue.async { [self] in
            let old = config
            config = new
            if new.claudeConfigDirs != old.claudeConfigDirs || new.codexHomes != old.codexHomes
                || new.codexRecentHours != old.codexRecentHours {
                tracker = Tracker(sources: makeSources(new), store: store, config: new)
            } else {
                tracker.config = new
            }
        }
    }

    /// Writes whatever is pending; call before exiting.
    func shutdown() {
        queue.sync {
            snapshot?.flush()
            do {
                try store.save(now: Date())
            } catch {
                Log.shared.error("could not save \(store.url.path): \(error.localizedDescription)")
            }
        }
    }

    private func tickOnQueue() -> Update {
        let events = tracker.tick()
        for event in events { Log.shared.info(Self.describe(event)) }
        let sessions = tracker.sessions
        snapshot?.submit(sessions, on: queue)
        return Update(sessions: sessions, events: events)
    }

    private func publish(_ deliver: @escaping @MainActor ([TrackedSession]) -> Void) {
        let sessions = tracker.sessions
        snapshot?.submit(sessions, on: queue)
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(sessions) } }
    }

    static func makeSources(for config: Config) -> [SessionSource] {
        var sources: [SessionSource] = []
        var watched: [String] = []
        if !config.claudeConfigDirs.isEmpty {
            sources.append(ClaudeSource(configDirs: config.claudeConfigURLs))
            watched.append("Claude in " + config.claudeConfigDirs.joined(separator: ", "))
        }
        if !config.codexHomes.isEmpty {
            sources.append(CodexSource(homes: config.codexHomeURLs, recentHours: config.codexRecentHours))
            watched.append("Codex in " + config.codexHomes.joined(separator: ", "))
        }
        Log.shared.info("watching " + (watched.isEmpty ? "nothing: no Claude dirs or Codex homes are configured"
                                                       : watched.joined(separator: "; ")))
        return sources
    }

    static func describe(_ event: TrackerEvent) -> String {
        switch event {
        case .finished(let session):
            let took = session.lastTurnDuration.map { " after \(Formatting.duration($0))" } ?? ""
            return "\(session.key) finished\(took): \(session.title) [\(session.project)]"
        case .needsInput(let session):
            return "\(session.key) needs input: \(session.title) [\(session.project)]"
        case .resumed(let key):
            return "\(key) resumed"
        case .ended(let key):
            return "\(key) ended"
        }
    }
}

// MARK: - Persistence helpers

/// Keeps `state/snapshot.json` (the visible sessions, for other tools and
/// `--headless`) current: at most one write per `delay`, always the latest
/// list, nothing when the list did not change. Used only on the engine queue.
final class SnapshotWriter {
    static var standardURL: URL { AppPaths.stateDir.appendingPathComponent("snapshot.json") }

    let url: URL
    let delay: TimeInterval
    private var pending: [TrackedSession]?
    private var written: [TrackedSession]?
    private var scheduled = false
    private var lastError: String?

    init(url: URL, delay: TimeInterval) {
        self.url = url
        self.delay = delay
    }

    func submit(_ sessions: [TrackedSession], on queue: DispatchQueue) {
        if sessions != (pending ?? written) { pending = sessions }
        // Still pending after a failed write: retried from here, once per delay.
        guard pending != nil else { return }
        guard delay > 0 else { return flush() }
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            scheduled = false
            flush()
        }
    }

    /// Writes the pending list now. A failed write stays pending.
    func flush() {
        guard let sessions = pending else { return }
        guard sessions != written else {
            pending = nil
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encoder.encode(Snapshot(updatedAt: Date(), sessions: sessions)).write(to: url, options: .atomic)
            written = sessions
            pending = nil
            lastError = nil
        } catch {
            let message = error.localizedDescription
            if message != lastError { Log.shared.error("could not write \(url.path): \(message)") }
            lastError = message
        }
    }

    struct Snapshot: Codable {
        var updatedAt: Date
        var sessions: [TrackedSession]
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// "Pause Notifications", persisted as the file `state/notifications-paused`.
struct PauseFlag {
    static var standard: PauseFlag { PauseFlag(url: AppPaths.stateDir.appendingPathComponent("notifications-paused")) }

    let url: URL

    var isPaused: Bool { FileManager.default.fileExists(atPath: url.path) }

    func set(_ paused: Bool) throws {
        let fm = FileManager.default
        if paused {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("paused from the AI Sessions menu\n".utf8).write(to: url, options: .atomic)
        } else if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}

/// Notices edits to one file by its stat stamp, without reading it.
struct ConfigWatcher {
    let url: URL
    private var stamp: Stamp?

    init(url: URL) {
        self.url = url
        stamp = Stamp(path: url.path)
    }

    /// True once per change since the last call: rewritten (mtime or size),
    /// replaced (an editor's atomic save makes a new inode), created or deleted.
    mutating func checkForChange() -> Bool {
        let current = Stamp(path: url.path)
        defer { stamp = current }
        return current != stamp
    }

    private struct Stamp: Equatable {
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }
}
