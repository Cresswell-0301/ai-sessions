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

/// The text and icon of one session row.
enum MenuRowText {
    /// "coreOS · Claude · 4m": project, agent, time in the current state.
    static func detail(for session: TrackedSession, now: Date) -> String {
        var parts = [session.project, session.key.agent.displayName].filter { !$0.isEmpty }
        if let since = session.stateSince { parts.append(Formatting.duration(now.timeIntervalSince(since))) }
        return parts.joined(separator: " · ")
    }

    static func symbol(for session: TrackedSession) -> (name: String, tint: SymbolTint) {
        if session.state == .waiting { return ("exclamationmark.bubble.fill", .attention) }
        if session.unread { return ("checkmark.circle.fill", .done) }
        return session.state == .running ? ("circle.dashed", .neutral) : ("circle", .neutral)
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
    }

    private let actions: Actions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var sessions: [TrackedSession] = []
    private var paused = false
    private var shown: StatusSummary?
    private var permission: Notifier.Permission = .unknown

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

        for section in MenuSections(sessions).nonEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: section.title))
            for session in section.sessions {
                menu.addItem(row(for: session, now: now))
                if session.unread { menu.addItem(markReadAlternate(for: session)) }
            }
        }

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
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
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

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.shared.fileURL)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(AppPaths.home)
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
