import AISessionsCore
import Foundation
@preconcurrency import UserNotifications

/// One notification for one session. Its identifier is the session key, so
/// a newer notification for a session replaces the older one.
struct SessionNotification: Equatable {
    var key: SessionKey
    var title: String
    var subtitle: String
    var body: String
    var playsSound: Bool
    /// A sample from "Send Test Notification". It has an identifier of its
    /// own ("test:<key>"), so it never replaces the session's real banner,
    /// usually the most important one (the menu tests the first listed
    /// session: waiting and unread ones come first).
    var isSample = false

    static let samplePrefix = "test:"

    var identifier: String { (isSample ? Self.samplePrefix : "") + key.description }

    static func isSample(identifier: String) -> Bool { identifier.hasPrefix(samplePrefix) }
}

/// Which tracker events become notifications, and what they say.
struct NotificationPolicy {
    var config: Config
    var paused: Bool

    func notification(for event: TrackerEvent) -> SessionNotification? {
        guard config.notificationsEnabled, !paused else { return nil }
        switch event {
        case .finished(let session):
            // A short turn was probably watched; an unknown length counts as short.
            guard session.interactive, let duration = session.lastTurnDuration,
                  duration >= config.minTurnSecondsToNotify else { return nil }
            return make(session, status: "done in \(Formatting.duration(duration))", fallbackBody: "Turn finished")
        case .needsInput(let session):
            return make(session, status: "needs your input", fallbackBody: "Waiting for your input")
        case .resumed, .ended:
            return nil
        }
    }

    /// Subtitle "Claude · coreOS · done in 4m"; the body previews the last message.
    private func make(_ session: TrackedSession, status: String, fallbackBody: String) -> SessionNotification {
        let subtitle = [session.key.agent.displayName, session.project, status]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return SessionNotification(
            key: session.key,
            title: session.title,
            subtitle: subtitle,
            body: Formatting.oneLine(session.lastMessage, max: 180) ?? fallbackBody,
            playsSound: config.sound)
    }
}

/// The calls the notifier makes on UNUserNotificationCenter. The app passes
/// the real center; tests pass a recorder, so a test run never posts or
/// removes a real banner (and runs outside an .app bundle, where the real
/// center raises).
protocol NotificationCenterClient: AnyObject {
    func install(delegate: UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>)
    func requestPermission(_ completion: @escaping (_ granted: Bool, _ error: Error?) -> Void)
    func authorization(_ completion: @escaping (UNAuthorizationStatus, UNAlertStyle) -> Void)
    func post(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
    func removeDelivered(_ identifiers: [String])
    func removePending(_ identifiers: [String])
    func removeAllDelivered()
    func removeAllPending()
    func deliveredIdentifiers(_ completion: @escaping ([String]) -> Void)
}

extension UNUserNotificationCenter: NotificationCenterClient {
    func install(delegate: UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>) {
        self.delegate = delegate
        setNotificationCategories(categories)
    }

    func requestPermission(_ completion: @escaping (Bool, Error?) -> Void) {
        requestAuthorization(options: [.alert, .sound]) { granted, error in completion(granted, error) }
    }

    func authorization(_ completion: @escaping (UNAuthorizationStatus, UNAlertStyle) -> Void) {
        getNotificationSettings { settings in completion(settings.authorizationStatus, settings.alertStyle) }
    }

    func post(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        add(request) { error in completion(error) }
    }

    func removeDelivered(_ identifiers: [String]) { removeDeliveredNotifications(withIdentifiers: identifiers) }
    func removePending(_ identifiers: [String]) { removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeAllDelivered() { removeAllDeliveredNotifications() }
    func removeAllPending() { removeAllPendingNotificationRequests() }

    func deliveredIdentifiers(_ completion: @escaping ([String]) -> Void) {
        getDeliveredNotifications { delivered in completion(delivered.map(\.request.identifier)) }
    }
}

/// Posts and withdraws the session notifications and answers their clicks.
/// UserNotifications calls the delegate methods on a background queue, so
/// they are `nonisolated` and hop to the main queue.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let categoryIdentifier = "session"

    enum Action {
        static let open = "open"
        static let markRead = "mark-read"
    }

    /// What a click on a notification (or one of its buttons) asks for.
    enum Intent: Equatable {
        case open
        case markRead
    }

    /// Whether macOS will actually show our notifications.
    enum Permission: Equatable {
        case unknown
        /// Allowed, and banners or alerts are on.
        case allowed
        /// Allowed, but the alert style is "None": only Notification Center.
        case silent
        /// Denied in System Settings, or a permission prompt that was never
        /// answered (macOS records an abandoned prompt as a refusal).
        case denied
        case notAsked

        /// Worth a fix-it row in the menu.
        var needsAttention: Bool { self == .denied || self == .silent }
    }

    /// A click on a banner: back to the session; `markingRead` is false for
    /// a sample banner, which says nothing about the session's state.
    var onOpen: (_ key: SessionKey, _ markingRead: Bool) -> Void = { _, _ in }
    var onMarkRead: (SessionKey) -> Void = { _ in }
    var onPermissionChange: (Permission) -> Void = { _ in }
    private(set) var permission: Permission = .unknown

    private let center: NotificationCenterClient
    private var reportedErrors: Set<String> = []

    init(center: NotificationCenterClient) {
        self.center = center
        super.init()
        center.install(delegate: self, categories: [UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [
                UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground]),
                UNNotificationAction(identifier: Action.markRead, title: "Mark as Read", options: []),
            ],
            intentIdentifiers: [])])
    }

    /// Once per launch. macOS asks the user only the first time; afterwards
    /// this just reports the stored answer.
    func requestAuthorization() {
        center.requestPermission { granted, error in
            if let error {
                Log.shared.warn("notification permission request failed: \(error.localizedDescription)")
            } else if granted {
                Log.shared.info("notifications are allowed")
            } else {
                Log.shared.warn("notifications are not allowed; turn them on in System Settings > Notifications > AI Sessions")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshPermission() } }
        }
    }

    /// Reads the current setting (cheap; the app polls it so that turning
    /// notifications on in System Settings clears the menu's fix-it row).
    func refreshPermission() {
        center.authorization { status, alertStyle in
            let permission = Self.permission(status: status, alertStyle: alertStyle)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.update(permission) }
            }
        }
    }

    nonisolated static func permission(status: UNAuthorizationStatus, alertStyle: UNAlertStyle) -> Permission {
        switch status {
        case .authorized, .provisional, .ephemeral: return alertStyle == .none ? .silent : .allowed
        case .denied: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .unknown
        }
    }

    private func update(_ permission: Permission) {
        guard permission != self.permission else { return }
        self.permission = permission
        switch permission {
        case .allowed: Log.shared.info("notification permission: allowed")
        case .silent: Log.shared.warn("notification permission: allowed, but the alert style is None (no banners)")
        case .denied: Log.shared.warn("notification permission: denied; System Settings > Notifications > AI Sessions")
        case .notAsked: Log.shared.info("notification permission: not asked yet")
        case .unknown: break
        }
        onPermissionChange(permission)
    }

    /// Posts and withdraws for one tick's events; returns the keys it posted.
    @discardableResult
    func handle(_ events: [TrackerEvent], config: Config, paused: Bool) -> Set<SessionKey> {
        let policy = NotificationPolicy(config: config, paused: paused)
        var posted = Set<SessionKey>()
        for event in events {
            switch event {
            case .finished(let session), .needsInput(let session):
                if let note = policy.notification(for: event) {
                    post(note)
                    posted.insert(session.key)
                } else {
                    // Whatever is still on screen for it describes an older state.
                    withdraw([session.key])
                    posted.remove(session.key)
                }
            case .resumed(let key):
                withdraw([key])
                posted.remove(key)
            case .ended:
                // The banner stays (DESIGN.md: removed when read or resumed).
                // A window reload or quit ends every session in it, and must
                // not erase results nobody has seen; a click on one still
                // routes, from the session's last known view.
                break
            }
        }
        return posted
    }

    func withdraw(_ keys: [SessionKey]) {
        guard !keys.isEmpty else { return }
        let ids = keys.map(\.description)
        center.removeDelivered(ids)
        center.removePending(ids)
    }

    func withdrawAll() {
        center.removeAllDelivered()
        center.removeAllPending()
    }

    /// Removes every delivered notification except those of `keys`.
    func removeDelivered(keeping keys: Set<SessionKey>) {
        let keep = Set(keys.map(\.description))
        center.deliveredIdentifiers { [center] delivered in
            let stale = delivered.filter { !keep.contains($0) }
            if !stale.isEmpty { center.removeDelivered(stale) }
        }
    }

    /// A sample banner for `session`: proves permission, style and the
    /// click-to-route path without waiting for a real turn to finish. It
    /// stands beside the session's real banner, not in its place.
    func postTest(for session: TrackedSession, sound: Bool) {
        let subtitle = [session.key.agent.displayName, session.project, "test notification"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        post(SessionNotification(key: session.key, title: session.title, subtitle: subtitle,
                                 body: "Click to jump back to this session.", playsSound: sound, isSample: true))
        Log.shared.info("test notification posted for \(session.key)")
    }

    private func post(_ note: SessionNotification) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.subtitle = note.subtitle
        content.body = note.body
        content.sound = note.playsSound ? .default : nil
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = note.key.description
        // The session to route to; for a sample it differs from the identifier.
        content.userInfo = ["key": note.key.description]
        let request = UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil)
        center.post(request) { error in
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.report(error) }
            }
        }
    }

    /// Logs each distinct posting error once (a denied permission would
    /// otherwise log on every finished turn).
    private func report(_ error: Error) {
        let message = error.localizedDescription
        guard reportedErrors.insert(message).inserted else { return }
        Log.shared.warn("could not post a notification: \(message)")
    }

    nonisolated static func intent(forAction action: String) -> Intent? {
        switch action {
        case UNNotificationDefaultActionIdentifier, Action.open: return .open
        case Action.markRead: return .markRead
        default: return nil // dismissed, or an action this version does not know
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let request = response.notification.request
        let identifier = request.identifier
        let key = request.content.userInfo["key"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.respond(action: action, identifier: identifier, key: key) }
            completionHandler()
        }
    }

    /// A click on a banner or one of its buttons. A click on a sample routes
    /// like a real one but leaves the session unread: testing the path back
    /// must not clear what the session is waiting to tell. Its "Mark as
    /// Read" button is an explicit request and still marks the session read.
    func respond(action: String, identifier: String, key: String?) {
        guard let key = key.flatMap(SessionKey.init(string:)) else { return }
        switch Self.intent(forAction: action) {
        case .open?: onOpen(key, !SessionNotification.isSample(identifier: identifier))
        case .markRead?: onMarkRead(key)
        case nil: break
        }
    }
}
