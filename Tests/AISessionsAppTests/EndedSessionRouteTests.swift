import XCTest
@testable import AISessions
@testable import AISessionsCore

/// A click on the notification of a session that has since ended (tab closed,
/// app restarted) must still route somewhere: the deep link reopens it.
final class EndedSessionRouteTests: XCTestCase {
    @MainActor
    func testEndedClaudeSessionDeepLinksToTheLastActiveWindow() {
        let key = SessionKey(agent: .claude, id: "9eb4895f-b5d9-41d0-8161-864ac0eecf46")
        let plan = Router.plan(for: AppDelegate.placeholder(for: key), family: .vscode, windowId: nil, liveWindows: 1)
        XCTAssertEqual(plan.url?.absoluteString,
                       "vscode://anthropic.claude-code/open?session=9eb4895f-b5d9-41d0-8161-864ac0eecf46")
    }

    @MainActor
    func testEndedCodexThreadDeepLinks() {
        let key = SessionKey(agent: .codex, id: "01a0c894-49df-7102-92b1-6cf77abbf88e")
        let plan = Router.plan(for: AppDelegate.placeholder(for: key), family: .vscode, windowId: nil, liveWindows: 1)
        XCTAssertEqual(plan.url?.absoluteString, "vscode://openai.chatgpt/local/01a0c894-49df-7102-92b1-6cf77abbf88e")
    }
}
