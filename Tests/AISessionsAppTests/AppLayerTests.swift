import AppKit
import AISessionsCore
import XCTest
@testable import AISessions

/// Shared session fixtures for the app tests.
enum AppFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_800_000)

    static func session(_ id: String, _ state: ActivityState, agent: Agent = .claude, unread: Bool = false,
                        project: String = "coreOS", title: String? = nil, since: TimeInterval? = 240,
                        lastTurn: TimeInterval? = nil, lastMessage: String? = nil, interactive: Bool = true,
                        lastChange: TimeInterval = 0) -> TrackedSession {
        TrackedSession(
            key: SessionKey(agent: agent, id: id), title: title ?? "Session \(id)", project: project,
            cwd: project.isEmpty ? nil : "/work/\(project)", state: state,
            stateSince: since.map { now.addingTimeInterval(-$0) }, lastTurnDuration: lastTurn,
            unread: unread, lastMessage: lastMessage, interactive: interactive,
            firstSeen: now.addingTimeInterval(-3600), lastChange: now.addingTimeInterval(-lastChange))
    }
}

final class LaunchModeTests: XCTestCase {
    func testModes() {
        XCTAssertEqual(LaunchMode.parse([]), .gui)
        XCTAssertEqual(LaunchMode.parse(["-psn_0_1234567"]), .gui, "Finder's process serial number is ignored")
        XCTAssertEqual(LaunchMode.parse(["--headless"]), .headless(useAppState: false))
        XCTAssertEqual(LaunchMode.parse(["--headless", "--use-app-state"]), .headless(useAppState: true))
        XCTAssertEqual(LaunchMode.parse(["--use-app-state", "--headless"]), .headless(useAppState: true))
        XCTAssertEqual(LaunchMode.parse(["--version"]), .version)
        XCTAssertEqual(LaunchMode.parse(["-h"]), .help)
        XCTAssertEqual(LaunchMode.parse(["--route", "claude:abc"]), .route(query: "claude:abc", open: false))
        XCTAssertEqual(LaunchMode.parse(["--route", "claude:abc", "--open"]), .route(query: "claude:abc", open: true))
        XCTAssertEqual(LaunchMode.parse(["--open", "--route", "claude:abc"]), .route(query: "claude:abc", open: true))
    }

    func testInvalidCommandLines() {
        for arguments in [["--open"], ["--route"], ["--route", "--open"], ["--headless", "--route", "x"],
                          ["--version", "--open"], ["--nope"], ["claude:abc"], ["--use-app-state"],
                          ["--route", "x", "--use-app-state"], ["--headless", "--open"]] {
            guard case .invalid = LaunchMode.parse(arguments) else {
                return XCTFail("\(arguments) should be rejected, got \(LaunchMode.parse(arguments))")
            }
        }
    }
}

final class SessionQueryTests: XCTestCase {
    private let sessions = [
        AppFixtures.session("9eb4895f-b5d9", .running),
        AppFixtures.session("9eb4895f-b5d9-41d0", .idle),
        AppFixtures.session("0199aa00", .idle, agent: .codex),
    ]

    func testAnExactKeyWinsOverALongerOneItPrefixes() {
        XCTAssertEqual(SessionQuery.match("claude:9eb4895f-b5d9", in: sessions), .found(sessions[0]))
    }

    func testAUniquePrefixOfAKeyOrOfAnIdMatches() {
        XCTAssertEqual(SessionQuery.match("codex:01", in: sessions), .found(sessions[2]))
        XCTAssertEqual(SessionQuery.match("0199", in: sessions), .found(sessions[2]))
    }

    func testAnAmbiguousOrUnknownQueryDoesNotGuess() {
        XCTAssertEqual(SessionQuery.match("9eb4", in: sessions), .ambiguous([sessions[0], sessions[1]]))
        XCTAssertEqual(SessionQuery.match("claude:ffff", in: sessions), .none)
        XCTAssertEqual(SessionQuery.match("claude:ffff", in: []), .none)
    }
}

final class StatusSummaryTests: XCTestCase {
    private func summary(_ sessions: [TrackedSession]) -> StatusSummary { StatusSummary(sessions: sessions) }

    func testNothingRunningShowsTheTemplateSparkles() {
        let empty = summary([])
        XCTAssertEqual(empty.symbolName, "sparkles")
        XCTAssertEqual(empty.tint, .neutral)
        XCTAssertEqual(empty.accessibilityLabel, "AI Sessions — no active sessions")
        XCTAssertEqual(empty.headline, "No active sessions")

        let idle = summary([AppFixtures.session("a", .idle), AppFixtures.session("b", .idle)])
        XCTAssertEqual(idle.symbolName, "sparkles")
        XCTAssertEqual(idle.accessibilityLabel, "AI Sessions — 2 idle")
        XCTAssertEqual(idle.headline, "2 idle")
    }

    func testRunningShowsTheRunningCountInATemplateCircle() {
        let s = summary([AppFixtures.session("a", .running), AppFixtures.session("b", .running),
                         AppFixtures.session("c", .idle)])
        XCTAssertEqual(s.symbolName, "2.circle")
        XCTAssertEqual(s.tint, .neutral)
        XCTAssertEqual(s.accessibilityLabel, "AI Sessions — 2 running")
        XCTAssertEqual(s.headline, "2 running · 1 idle")
    }

    func testUnreadShowsTheUnreadCountInAGreenFilledCircle() {
        let sessions = [AppFixtures.session("a", .idle, unread: true), AppFixtures.session("b", .idle, unread: true),
                        AppFixtures.session("c", .running), AppFixtures.session("d", .running),
                        AppFixtures.session("e", .running)]
        let s = summary(sessions)
        XCTAssertEqual(s.symbolName, "2.circle.fill", "unread wins over running")
        XCTAssertEqual(s.tint, .done)
        XCTAssertEqual(s.accessibilityLabel, "AI Sessions — 2 need you, 3 running")

        XCTAssertEqual(summary([sessions[0]]).symbolName, "1.circle.fill")
        XCTAssertEqual(summary([sessions[0]]).accessibilityLabel, "AI Sessions — 1 needs you")
    }

    func testCountsBeyondTheNumberedSymbolsFallBackToAnEllipsis() {
        XCTAssertEqual(StatusSummary.counted(50, filled: false), "50.circle")
        XCTAssertEqual(StatusSummary.counted(51, filled: false), "ellipsis.circle")
        XCTAssertEqual(StatusSummary.counted(51, filled: true), "ellipsis.circle.fill")
        for name in ["1.circle", "50.circle.fill", "ellipsis.circle.fill", "sparkles"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) must exist")
        }
    }

    func testWaitingWinsWithOrangeAndCountsEveryoneWhoNeedsYou() {
        let s = summary([AppFixtures.session("a", .waiting, unread: true), AppFixtures.session("b", .idle, unread: true),
                         AppFixtures.session("c", .idle, unread: true), AppFixtures.session("d", .running)])
        XCTAssertEqual(s.symbolName, "3.circle.fill")
        XCTAssertEqual(s.tint, .attention)
        XCTAssertEqual(s.waiting, 1)
        XCTAssertEqual(s.unread, 2, "an unread waiting session counts once, as waiting")
        XCTAssertEqual(s.accessibilityLabel, "AI Sessions — 3 need you, 1 running")
        XCTAssertEqual(s.headline, "3 need you · 1 running")
    }
}

final class MenuLayoutTests: XCTestCase {
    func testSectionsKeepDisplayOrderAndOmitEmptyOnes() {
        let waiting = AppFixtures.session("w", .waiting)
        let unread = AppFixtures.session("u", .idle, unread: true)
        let running = AppFixtures.session("r", .running)
        let idle = AppFixtures.session("i", .idle)

        let sections = MenuSections([waiting, unread, running, idle])
        XCTAssertEqual(sections.needsYou, [waiting, unread])
        XCTAssertEqual(sections.running, [running])
        XCTAssertEqual(sections.idle, [idle])
        XCTAssertEqual(sections.nonEmpty.map(\.title), ["Needs you", "Running", "Idle"])

        XCTAssertEqual(MenuSections([idle]).nonEmpty.map(\.title), ["Idle"])
        XCTAssertTrue(MenuSections([]).nonEmpty.isEmpty)
    }

    func testRowDetailIsProjectAgentAndTimeInState() {
        let now = AppFixtures.now
        XCTAssertEqual(MenuRowText.detail(for: AppFixtures.session("a", .running, since: 240), now: now),
                       "coreOS · Claude · 4m")
        XCTAssertEqual(MenuRowText.detail(for: AppFixtures.session("b", .idle, agent: .codex, project: "", since: 8),
                                          now: now), "Codex · 8s")
        XCTAssertEqual(MenuRowText.detail(for: AppFixtures.session("c", .idle, since: nil), now: now),
                       "coreOS · Claude")
    }

    func testRowSymbolFollowsTheState() {
        XCTAssertEqual(MenuRowText.symbol(for: AppFixtures.session("a", .waiting, unread: true)).name,
                       "exclamationmark.bubble.fill")
        XCTAssertEqual(MenuRowText.symbol(for: AppFixtures.session("b", .idle, unread: true)).tint, .done)
        XCTAssertEqual(MenuRowText.symbol(for: AppFixtures.session("c", .running)).name, "circle.dashed")
        XCTAssertEqual(MenuRowText.symbol(for: AppFixtures.session("d", .idle)).tint, .neutral)
    }

    func testHeadlessListingLabelsUnreadSeparately() {
        XCTAssertEqual(SessionListing.stateLabel(AppFixtures.session("a", .idle, unread: true)), "unread")
        XCTAssertEqual(SessionListing.stateLabel(AppFixtures.session("b", .waiting, unread: true)), "waiting")
        XCTAssertEqual(SessionListing.stateLabel(AppFixtures.session("c", .running)), "running")
    }
}
