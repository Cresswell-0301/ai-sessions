import AISessionsCore
import UserNotifications
import XCTest
@testable import AISessions

/// What gets posted, and what it says. Only the pure policy is exercised:
/// nothing here touches UNUserNotificationCenter.
final class NotificationPolicyTests: XCTestCase {
    private var config = Config()
    private var policy: NotificationPolicy { NotificationPolicy(config: config, paused: false) }

    private func finished(lastTurn: TimeInterval?, interactive: Bool = true, message: String? = "Done: 3 files.",
                          project: String = "coreOS") -> TrackerEvent {
        .finished(AppFixtures.session("9eb4895f", .idle, unread: true, project: project, title: "AI Track",
                                      lastTurn: lastTurn, lastMessage: message, interactive: interactive))
    }

    private func needsInput(message: String? = "May I run the migration?") -> TrackerEvent {
        .needsInput(AppFixtures.session("9eb4895f", .waiting, unread: true, title: "AI Track", lastMessage: message))
    }

    func testALongFinishedTurnIsAnnouncedWithItsLength() throws {
        let note = try XCTUnwrap(policy.notification(for: finished(lastTurn: 240)))
        XCTAssertEqual(note.identifier, "claude:9eb4895f")
        XCTAssertEqual(note.title, "AI Track")
        XCTAssertEqual(note.subtitle, "Claude · coreOS · done in 4m")
        XCTAssertEqual(note.body, "Done: 3 files.")
        XCTAssertTrue(note.playsSound)
    }

    func testTheThresholdIsInclusive() {
        config.minTurnSecondsToNotify = 10
        XCTAssertNotNil(policy.notification(for: finished(lastTurn: 10)))
        XCTAssertNil(policy.notification(for: finished(lastTurn: 9.9)), "a short turn was probably watched")
    }

    func testAFinishedTurnOfUnknownLengthOrFromAutomationIsNotAnnounced() {
        XCTAssertNil(policy.notification(for: finished(lastTurn: nil)))
        XCTAssertNil(policy.notification(for: finished(lastTurn: 600, interactive: false)))
    }

    func testNeedsInputIsAnnouncedWhateverTheTurnLength() throws {
        let note = try XCTUnwrap(policy.notification(for: needsInput()))
        XCTAssertEqual(note.subtitle, "Claude · coreOS · needs your input")
        XCTAssertEqual(note.body, "May I run the migration?")
    }

    func testPausedOrDisabledAnnouncesNothing() {
        for (enabled, paused) in [(true, true), (false, false)] {
            config.notificationsEnabled = enabled
            let policy = NotificationPolicy(config: config, paused: paused)
            XCTAssertNil(policy.notification(for: finished(lastTurn: 600)), "enabled \(enabled), paused \(paused)")
            XCTAssertNil(policy.notification(for: needsInput()), "enabled \(enabled), paused \(paused)")
        }
    }

    func testResumedAndEndedAreNeverAnnounced() {
        XCTAssertNil(policy.notification(for: .resumed(SessionKey(agent: .claude, id: "x"))))
        XCTAssertNil(policy.notification(for: .ended(SessionKey(agent: .codex, id: "y"))))
    }

    func testSoundFollowsTheConfig() throws {
        config.sound = false
        XCTAssertFalse(try XCTUnwrap(policy.notification(for: needsInput())).playsSound)
    }

    func testBodyIsAOneLinePreviewWithAFallback() throws {
        let long = String(repeating: "word ", count: 100) + "\n\nend"
        let body = try XCTUnwrap(policy.notification(for: finished(lastTurn: 60, message: long))).body
        XCTAssertEqual(body.count, 180)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertFalse(body.contains("\n"))

        XCTAssertEqual(policy.notification(for: finished(lastTurn: 60, message: "  \n "))?.body, "Turn finished")
        XCTAssertEqual(policy.notification(for: needsInput(message: nil))?.body, "Waiting for your input")
    }

    func testAnEmptyProjectIsLeftOutOfTheSubtitle() {
        XCTAssertEqual(policy.notification(for: finished(lastTurn: 75, project: ""))?.subtitle, "Claude · done in 1m")
    }

    func testClicksMapToIntents() {
        XCTAssertEqual(Notifier.intent(forAction: UNNotificationDefaultActionIdentifier), .open)
        XCTAssertEqual(Notifier.intent(forAction: Notifier.Action.open), .open)
        XCTAssertEqual(Notifier.intent(forAction: Notifier.Action.markRead), .markRead)
        XCTAssertNil(Notifier.intent(forAction: UNNotificationDismissActionIdentifier))
    }
}

final class NotificationPermissionTests: XCTestCase {
    func testPermissionMapping() {
        XCTAssertEqual(Notifier.permission(status: .authorized, alertStyle: .banner), .allowed)
        XCTAssertEqual(Notifier.permission(status: .authorized, alertStyle: .alert), .allowed)
        XCTAssertEqual(Notifier.permission(status: .authorized, alertStyle: .none), .silent)
        XCTAssertEqual(Notifier.permission(status: .denied, alertStyle: .none), .denied)
        XCTAssertEqual(Notifier.permission(status: .notDetermined, alertStyle: .none), .notAsked)
    }

    @MainActor
    func testFixItRowOnlyWhenBannersCannotAppear() {
        XCTAssertEqual(StatusMenuController.permissionFixTitle(.denied), "Notifications are off — Turn On…")
        XCTAssertNotNil(StatusMenuController.permissionFixTitle(.silent))
        XCTAssertNil(StatusMenuController.permissionFixTitle(.allowed))
        XCTAssertNil(StatusMenuController.permissionFixTitle(.notAsked))
        XCTAssertNil(StatusMenuController.permissionFixTitle(.unknown))
    }
}
