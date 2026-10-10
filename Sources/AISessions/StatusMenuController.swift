import AISessionsCore
import AppKit

/// How a symbol is colored: a fixed color, or a template the menu bar tints.
enum SymbolTint: Equatable {
    case attention // orange: waiting on the user
    case done      // green: finished, not seen yet
    case neutral   // template

    var color: NSColor? {
        switch self {
        case .attention: return .systemOrange
        case .done: return .systemGreen
        case .neutral: return nil
        }
    }
}

/// What the menu-bar button shows for a set of visible sessions
/// (DESIGN.md "App behavior"). The count is drawn inside the symbol
/// ("3.circle.fill") rather than as text beside it: a notched MacBook's menu
/// bar has little room right of the notch, and every point this item takes
/// can push another app's item behind the notch.
struct StatusSummary: Equatable {
    let waiting: Int
    /// Finished and unread (waiting sessions are counted as waiting only).
    let unread: Int
    let running: Int
    let idle: Int
    let symbolName: String
    let tint: SymbolTint

    init(sessions: [TrackedSession]) {
        var waiting = 0, unread = 0, running = 0, idle = 0
        for session in sessions {
            if session.state == .waiting {
                waiting += 1
            } else if session.unread {
                unread += 1
            } else if session.state == .running {
                running += 1
            } else {
                idle += 1
            }
        }
        (self.waiting, self.unread, self.running, self.idle) = (waiting, unread, running, idle)
        if waiting > 0 {
            (symbolName, tint) = (Self.counted(waiting + unread, filled: true), .attention)
        } else if unread > 0 {
            (symbolName, tint) = (Self.counted(unread, filled: true), .done)
        } else if running > 0 {
            (symbolName, tint) = (Self.counted(running, filled: false), .neutral)
        } else {
            (symbolName, tint) = ("sparkles", .neutral)
        }
    }

    /// "3.circle" / "3.circle.fill"; SF Symbols numbers its circles 0–50.
    static func counted(_ count: Int, filled: Bool) -> String {
        let base = (1...50).contains(count) ? "\(count).circle" : "ellipsis.circle"
        return filled ? base + ".fill" : base
    }

    var needYou: Int { waiting + unread }

    /// "AI Sessions — 2 need you, 3 running".
    var accessibilityLabel: String {
        var parts: [String] = []
        if needYou > 0 { parts.append(needYou == 1 ? "1 needs you" : "\(needYou) need you") }
        if running > 0 { parts.append("\(running) running") }
        if parts.isEmpty { parts.append(idle > 0 ? "\(idle) idle" : "no active sessions") }
        return "\(AppInfo.name) — " + parts.joined(separator: ", ")
    }

    /// The menu's first line: "2 need you · 3 running · 1 idle".
    var headline: String {
        var parts: [String] = []
        if needYou > 0 { parts.append(needYou == 1 ? "1 needs you" : "\(needYou) need you") }
        if running > 0 { parts.append("\(running) running") }
        if idle > 0 { parts.append("\(idle) idle") }
        return parts.isEmpty ? "No active sessions" : parts.joined(separator: " · ")
    }
}

/// The menu's session sections, each in the tracker's display order.
struct MenuSections: Equatable {
    var needsYou: [TrackedSession] = []
    var running: [TrackedSession] = []
    var idle: [TrackedSession] = []

    init(_ sessions: [TrackedSession]) {
        for session in sessions {
            if session.needsAttention {
                needsYou.append(session)
            } else if session.state == .running {
                running.append(session)
            } else {
                idle.append(session)
            }
        }
    }

    /// Titled sections, empty ones omitted.
    var nonEmpty: [(title: String, sessions: [TrackedSession])] {
        [("Needs you", needsYou), ("Running", running), ("Idle", idle)].filter { !$0.1.isEmpty }
    }
}

/// config.json cannot be used (unreadable, or not a JSON object): why, and
/// what runs instead. A menu row says so until the file reads again, since a
/// log line alone goes unseen while settings quietly differ from the file.
struct ConfigProblem: Equatable {
    var reason: String
    /// Nothing better to keep: a launch with a broken file and no last good
    /// copy runs on the defaults.
    var usingDefaults: Bool

    var menuTitle: String {
        "config.json has an error — using \(usingDefaults ? "default" : "previous") settings"
    }
}

/// The text and icon of one session row.
enum MenuRowText {
    /// "coreOS · Claude · 4m": project, agent, time in the current state.
    static func detail(for session: TrackedSession, now: Date) -> String {
        var parts = [session.project, session.key.agent.displayName].filter { !$0.isEmpty }
        if let since = session.stateSince { parts.append(Formatting.duration(now.timeIntervalSince(since))) }
        if session.rawStatus == ClaudeSource.answeredWhileBusy { parts.append("background work running") }
        return parts.joined(separator: " · ")
    }

    static func symbol(for session: TrackedSession) -> (name: String, tint: SymbolTint) {
        if session.state == .waiting { return ("exclamationmark.bubble.fill", .attention) }
        if session.unread { return ("checkmark.circle.fill", .done) }
        return session.state == .running ? ("circle.dashed", .neutral) : ("circle", .neutral)
    }
}

/// The words and marks of the "Usage limits" submenu, from the latest
/// dashboard reading. Pure, so each wording is pinned by a test.
enum UsageMenu {
    struct State: Equatable {
        var enabled = true
        var threshold: Double = 90
        var status = UsageMonitor.Status()
        /// "@bot → Name" once Telegram is connected, else nil.
        var telegram: String?
        var telegramEnabled = true
        /// Why the last message to Telegram failed; nil once one went through.
        var telegramProblem: String?
        /// Alerts kept for a retry, and when the next try is.
        var telegramWaiting = 0
        var telegramNextTry: Date?
        /// A setup dialog is open: its menu item waits.
        var settingUpTelegram = false
    }

    /// The account this Mac is signed into, with its limits: "Usage limits —
    /// cresswell-nexxatech at 62% weekly · 31% session". With every account
    /// followed, the count over the threshold; otherwise why there is none.
    static func title(_ state: State, now: Date) -> String {
        guard state.enabled else { return "Usage limits — alerts off" }
        guard let snapshot = state.status.snapshot else {
            return state.status.problem == nil ? "Usage limits — checking…" : "Usage limits — dashboard not reachable"
        }
        let stale = state.status.problem == nil ? "" : " (last known)"
        let threshold = Int(state.threshold.rounded())
        let scope = state.status.scope
        if scope.everyAccount {
            let over = snapshot.over(state.threshold)
            return over.isEmpty ? "Usage limits — all under \(threshold)%\(stale)"
                                : "Usage limits — \(over.count) at \(threshold)%+\(stale)"
        }
        if scope.needsSignedIn, state.status.signedIn == nil { return "Usage limits — can't tell which account is in use" }
        let covered = state.status.covered
        switch covered.count {
        case 0:
            guard let email = state.status.signedIn?.sorted().first else { return "Usage limits — no account followed" }
            return "Usage limits — \(email) is not on the dashboard"
        case 1:
            return "Usage limits — \(UsageText.atUsage(covered[0]))\(stale)"
        default:
            let over = covered.filter { $0.isOver(state.threshold, at: snapshot.fetchedAt) }
            return over.isEmpty ? "Usage limits — \(covered.count) followed, all under \(threshold)%\(stale)"
                                : "Usage limits — \(over.count) of \(covered.count) followed at \(threshold)%+\(stale)"
        }
    }

    /// The submenu's first line: whose crossings alert.
    static func followed(_ state: State) -> String {
        let scope = state.status.scope
        if scope.everyAccount { return "Alerts for every account" }
        if scope.needsSignedIn, state.status.signedIn == nil { return "Alerts wait: no Claude sign-in found" }
        let inUse = state.status.inUse
        let labels = state.status.covered.map { inUse.contains($0.key) ? "\($0.label) (in use)" : $0.label }
        return labels.isEmpty ? "Alerts for nobody: the account in use is not on the dashboard"
                              : "Alerts for " + labels.joined(separator: ", ")
    }

    /// A warning only for an account the alerts follow.
    static func topSymbol(_ state: State) -> (name: String, tint: SymbolTint) {
        guard state.enabled, let snapshot = state.status.snapshot else { return ("gauge.with.dots.needle.33percent", .neutral) }
        let anyOver = state.status.covered.contains { $0.isOver(state.threshold, at: snapshot.fetchedAt) }
        return anyOver ? ("exclamationmark.triangle.fill", .attention) : ("gauge.with.dots.needle.33percent", .neutral)
    }

    /// Followed accounts first; then Claude before Codex, fullest first.
    static func sorted(_ accounts: [UsageAccount], followed: Set<String> = []) -> [UsageAccount] {
        accounts.sorted { lhs, rhs in
            let l = followed.contains(lhs.key), r = followed.contains(rhs.key)
            if l != r { return l }
            if lhs.tool != rhs.tool { return lhs.tool == "claude" }
            return (lhs.binding?.pct ?? -1) > (rhs.binding?.pct ?? -1)
        }
    }

    static func symbol(for account: UsageAccount, threshold: Double, at date: Date) -> (name: String, tint: SymbolTint) {
        guard account.readable else { return ("questionmark.circle", .neutral) }
        let over = account.isOver(threshold, at: date)
        return over ? ("exclamationmark.triangle.fill", .attention) : ("gauge.with.dots.needle.33percent", .neutral)
    }

    /// "weekly resets in 2d 4h · session resets in 3h 10m".
    static func resetsTooltip(_ account: UsageAccount, now: Date) -> String? {
        // Only windows in use: an untouched window's reset says nothing.
        let parts = account.windows.filter { $0.pct > 0 }.compactMap { window -> String? in
            UsageText.until(window.resetsAt, now: now).map { "\(window.shortName) resets in \($0)" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Telegram rows of the submenu, when a bot is connected: where the
    /// alerts go, why the last one failed, what waits for a retry.
    static func telegramLines(_ state: State, now: Date) -> [String] {
        guard let telegram = state.telegram else { return [] }
        guard state.telegramEnabled else { return ["Telegram: off (telegramAlerts in config.json)"] }
        var lines: [String] = []
        if let problem = state.telegramProblem {
            lines.append("Telegram: not delivering — \(telegram)")
            lines.append(Formatting.oneLine(problem, max: 90) ?? problem)
        } else {
            lines.append("Telegram: \(telegram)")
        }
        if state.telegramWaiting > 0 {
            let alerts = state.telegramWaiting == 1 ? "1 alert waits" : "\(state.telegramWaiting) alerts wait"
            let next = state.telegramNextTry.map { $0 > now ? " — next try in \(UsageText.until($0, now: now) ?? "a moment")" : " — sending" } ?? ""
            lines.append(alerts + " to be sent" + next)
        }
        return lines
    }

    /// "Updated just now" / "Updated 4m ago — dashboard not reachable".
    static func freshness(_ state: State, now: Date) -> String {
        let when = state.status.snapshot.map { Formatting.ago($0.fetchedAt, now: now) } ?? ""
        let age = when == "just now" ? "Updated just now" : "Updated \(when)"
        return state.status.problem == nil ? age : age + " — dashboard not reachable"
    }
}

/// The menu-bar item and its menu. The menu is rebuilt each time it opens,
/// from the latest snapshot the app handed over.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    struct Actions {
        var open: (SessionKey) -> Void
        var markRead: (SessionKey) -> Void
        var markAllRead: () -> Void
        var togglePause: () -> Void
        /// Posts a sample notification for the first listed session.
        var sendTestNotification: () -> Void = {}
        var openDashboard: () -> Void = {}
        var setUpTelegram: () -> Void = {}
        var testTelegram: () -> Void = {}
        var disconnectTelegram: () -> Void = {}
    }

    private let actions: Actions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var sessions: [TrackedSession] = []
    private var paused = false
    private var shown: StatusSummary?
    private var permission: Notifier.Permission = .unknown
    private var configProblem: ConfigProblem?
    private var usage = UsageMenu.State()

    static let autosaveName = "ai-sessions"
    /// Where a first launch places the item: macOS orders status items by
    /// this per-item key, larger = further left, and appends an item without
    /// one at the far left — behind the notch when the bar is full. 268 sits
    /// between Spotlight (252) and Battery (284) on this Mac. A ⌘-drag by the
    /// user stores their own value, which this never overrides.
    static let seedPosition = 268.0
    /// Fixed width of a single symbol, like Spotlight's. macOS 26 pads each
    /// item's window by 16 pt, so this occupies 32 pt — exactly the room this
    /// Mac's bar had left of the notch (`squareLength` would take 38).
    static let itemLength: CGFloat = 16

    init(actions: Actions, defaults: UserDefaults = .standard) {
        self.actions = actions
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if defaults.object(forKey: positionKey) == nil {
            defaults.set(Self.seedPosition, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: Self.itemLength)
        super.init()
        statusItem.autosaveName = Self.autosaveName
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// Shown as a fix-it row at the top of the menu when banners cannot appear.
    func setNotificationPermission(_ permission: Notifier.Permission) {
        self.permission = permission
    }

    /// What the "Usage limits" submenu shows; read when the menu opens.
    func setUsage(_ state: UsageMenu.State) {
        usage = state
    }

    /// Shown as a row that opens config.json while the file cannot be used.
    func setConfigProblem(_ problem: ConfigProblem?) {
        configProblem = problem
    }

    static func permissionFixTitle(_ permission: Notifier.Permission) -> String? {
        switch permission {
        case .denied: return "Notifications are off — Turn On…"
        case .silent: return "Notifications are silent (style: None) — Change…"
        case .allowed, .notAsked, .unknown: return nil
        }
    }

    func update(sessions: [TrackedSession], paused: Bool) {
        self.sessions = sessions
        self.paused = paused
        let summary = StatusSummary(sessions: sessions)
        guard summary != shown, let button = statusItem.button else { return }
        shown = summary
        button.image = Self.image(summary.symbolName, tint: summary.tint, pointSize: 13.5,
                                  description: summary.accessibilityLabel)
        button.imagePosition = .imageOnly
        button.toolTip = summary.accessibilityLabel
        button.setAccessibilityLabel(summary.accessibilityLabel)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let summary = StatusSummary(sessions: sessions)
        menu.addItem(disabledItem(summary.headline))
        if paused { menu.addItem(disabledItem("Notifications paused")) }
        if let fix = Self.permissionFixTitle(permission) {
            let row = item(fix, #selector(openNotificationSettings))
            row.image = Self.image("exclamationmark.triangle.fill", tint: .attention, pointSize: 13,
                                   description: "Notifications need attention")
            menu.addItem(row)
        }
        if let problem = configProblem {
            let row = item(problem.menuTitle, #selector(openConfig))
            row.image = Self.image("exclamationmark.triangle.fill", tint: .attention, pointSize: 13,
                                   description: "config.json has an error")
            row.toolTip = problem.reason
            menu.addItem(row)
        }

        for section in MenuSections(sessions).nonEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: section.title))
            for session in section.sessions {
                menu.addItem(row(for: session, now: now))
                if session.unread { menu.addItem(markReadAlternate(for: session)) }
            }
        }

        menu.addItem(.separator())
        menu.addItem(usageItem(now: now))

        menu.addItem(.separator())
        let markAll = item("Mark All as Read", #selector(markAllRead))
        markAll.isEnabled = sessions.contains(where: \.unread)
        menu.addItem(markAll)
        menu.addItem(item(paused ? "Resume Notifications" : "Pause Notifications", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(item("Open Folder", #selector(openFolder)))
        menu.addItem(item("Notification Settings…", #selector(openNotificationSettings)))
        menu.addItem(item("Send Test Notification", #selector(sendTestNotification)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    // MARK: Usage limits

    private func usageItem(now: Date) -> NSMenuItem {
        let top = NSMenuItem(title: UsageMenu.title(usage, now: now), action: nil, keyEquivalent: "")
        let symbol = UsageMenu.topSymbol(usage)
        top.image = Self.image(symbol.name, tint: symbol.tint, pointSize: 13, description: "Usage limits")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if usage.enabled, let snapshot = usage.status.snapshot {
            sub.addItem(disabledItem(UsageMenu.followed(usage)))
            let followed = Set(usage.status.covered.map(\.key))
            let inUse = usage.status.inUse
            for account in UsageMenu.sorted(snapshot.accounts, followed: followed) {
                let title = UsageText.menuRow(account) + (inUse.contains(account.key) ? "  ◀ in use" : "")
                let row = item(title, #selector(openDashboard))
                let mark = UsageMenu.symbol(for: account, threshold: usage.threshold, at: snapshot.fetchedAt)
                row.image = Self.image(mark.name, tint: mark.tint, pointSize: 12, description: account.label)
                row.state = followed.contains(account.key) ? .on : .off
                row.toolTip = UsageMenu.resetsTooltip(account, now: now)
                sub.addItem(row)
            }
            sub.addItem(.separator())
            sub.addItem(disabledItem(UsageMenu.freshness(usage, now: now)))
        } else if let problem = usage.status.problem {
            sub.addItem(disabledItem(problem))
        } else if !usage.enabled {
            sub.addItem(disabledItem("Usage alerts are off (usageAlertsEnabled in config.json)"))
        }
        sub.addItem(item("Open Dashboard", #selector(openDashboard)))
        sub.addItem(.separator())
        for (index, line) in UsageMenu.telegramLines(usage, now: now).enumerated() {
            let row = disabledItem(line)
            if index == 0, usage.telegramProblem != nil, usage.telegramEnabled {
                row.image = Self.image("exclamationmark.triangle.fill", tint: .attention, pointSize: 12,
                                       description: "Telegram is not delivering")
                row.toolTip = usage.telegramProblem
            }
            sub.addItem(row)
        }
        let setUp = item(Self.setUpTitle(usage), #selector(setUpTelegram))
        setUp.isEnabled = !usage.settingUpTelegram
        if usage.telegram == nil || usage.telegramProblem != nil || usage.settingUpTelegram { sub.addItem(setUp) }
        if usage.telegram != nil {
            sub.addItem(item("Send Test Message to Telegram", #selector(testTelegram)))
            sub.addItem(item("Disconnect Telegram…", #selector(disconnectTelegram)))
        }
        top.submenu = sub
        return top
    }

    static func setUpTitle(_ state: UsageMenu.State) -> String {
        if state.settingUpTelegram { return "Setting Up Telegram…" }
        return state.telegram == nil ? "Set Up Telegram Alerts…" : "Set Up Telegram Again…"
    }

    // MARK: Rows

    private func row(for session: TrackedSession, now: Date) -> NSMenuItem {
        let row = item(session.title, #selector(openSession(_:)))
        row.representedObject = session.key
        row.attributedTitle = Self.rowTitle(session.title, detail: MenuRowText.detail(for: session, now: now))
        let symbol = MenuRowText.symbol(for: session)
        row.image = Self.image(symbol.name, tint: symbol.tint, pointSize: 13, description: session.state.rawValue)
        row.toolTip = Formatting.oneLine(session.lastMessage, max: 300)
        return row
    }

    /// Shown in place of the row while ⌥ is held.
    private func markReadAlternate(for session: TrackedSession) -> NSMenuItem {
        let alternate = item("Mark as Read", #selector(markSessionRead(_:)))
        alternate.representedObject = session.key
        alternate.attributedTitle = Self.rowTitle("Mark as Read", detail: session.title)
        alternate.image = Self.image("checkmark", tint: .neutral, pointSize: 13, description: "Mark as Read")
        alternate.isAlternate = true
        alternate.keyEquivalentModifierMask = .option
        return alternate
    }

    private static func rowTitle(_ title: String, detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: Formatting.oneLine(title, max: 60) ?? title,
                                             attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    private static func image(_ name: String, tint: SymbolTint, pointSize: CGFloat, description: String) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let color = tint.color {
            // Two colors: the glyph inside (a count, a check, a "!") stays
            // white. With one, it takes the shape's color and vanishes,
            // leaving a plain dot in the menu bar.
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = tint == .neutral
        return image
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func openSession(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? SessionKey { actions.open(key) }
    }

    @objc private func markSessionRead(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? SessionKey { actions.markRead(key) }
    }

    @objc private func markAllRead() { actions.markAllRead() }

    @objc private func togglePause() { actions.togglePause() }

    @objc private func sendTestNotification() { actions.sendTestNotification() }

    @objc private func openDashboard() { actions.openDashboard() }

    @objc private func setUpTelegram() { actions.setUpTelegram() }

    @objc private func testTelegram() { actions.testTelegram() }

    @objc private func disconnectTelegram() { actions.disconnectTelegram() }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.shared.fileURL)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(AppPaths.home)
    }

    /// In the app that opens JSON; in Finder when there is none.
    @objc private func openConfig() {
        let url = AppPaths.home.appendingPathComponent("config.json")
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? AppInfo.bundleIdentifier
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
