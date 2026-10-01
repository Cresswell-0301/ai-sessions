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

    var identifier: String { key.description }
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

    var onOpen: (SessionKey) -> Void = { _ in }
    var onMarkRead: (SessionKey) -> Void = { _ in }
    var onPermissionChange: (Permission) -> Void = { _ in }
    private(set) var permission: Permission = .unknown

    private let center: UNUserNotificationCenter
    private var reportedErrors: Set<String> = []

    init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
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
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
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
        center.getNotificationSettings { settings in
            let permission = Self.permission(status: settings.authorizationStatus, alertStyle: settings.alertStyle)
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

    func handle(_ events: [TrackerEvent], config: Config, paused: Bool) {
        let policy = NotificationPolicy(config: config, paused: paused)
        for event in events {
            switch event {
            case .finished(let session), .needsInput(let session):
                if let note = policy.notification(for: event) {
                    post(note)
                } else {
                    // Whatever is still on screen for it describes an older state.
                    withdraw([session.key])
                }
            case .resumed(let key), .ended(let key):
                withdraw([key])
            }
        }
    }

    func withdraw(_ keys: [SessionKey]) {
        guard !keys.isEmpty else { return }
        let ids = keys.map(\.description)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func withdrawAll() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// Removes every delivered notification except those of `keys`.
    func removeDelivered(keeping keys: Set<SessionKey>) {
        let keep = Set(keys.map(\.description))
        center.getDeliveredNotifications { [center] delivered in
            let stale = delivered.map(\.request.identifier).filter { !keep.contains($0) }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// A sample banner for `session`: proves permission, style and the
    /// click-to-route path without waiting for a real turn to finish.
    func postTest(for session: TrackedSession, sound: Bool) {
        let subtitle = [session.key.agent.displayName, session.project, "test notification"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        post(SessionNotification(key: session.key, title: session.title, subtitle: subtitle,
                                 body: "Click to jump back to this session.", playsSound: sound))
        Log.shared.info("test notification posted for \(session.key)")
    }

    private func post(_ note: SessionNotification) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.subtitle = note.subtitle
        content.body = note.body
        content.sound = note.playsSound ? .default : nil
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = note.identifier
        content.userInfo = ["key": note.identifier]
        let request = UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil)
        center.add(request) { error in
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
        let intent = Self.intent(forAction: response.actionIdentifier)
        let key = (response.notification.request.content.userInfo["key"] as? String).flatMap(SessionKey.init(string:))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch (intent, key) {
                case (.open?, let key?): self.onOpen(key)
                case (.markRead?, let key?): self.onMarkRead(key)
                default: break
                }
            }
            completionHandler()
        }
    }
}
