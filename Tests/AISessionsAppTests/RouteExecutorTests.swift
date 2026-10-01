import AISessionsCore
import XCTest
@testable import AISessions

/// The fallback order of a route. A recorder stands in for NSWorkspace, so
/// nothing is opened or activated.
@MainActor
final class RouteExecutorTests: XCTestCase {
    private final class Recorder: RouteActions {
        var opens = true
        var activatesPid = true
        var activatesApp = true
        private(set) var calls: [String] = []

        func open(_ url: URL) -> Bool {
            calls.append("open \(url.absoluteString)")
            return opens
        }

        func activate(pid: Int32) -> Bool {
            calls.append("activate pid \(pid)")
            return activatesPid
        }

        func activate(bundleIdentifier: String) -> Bool {
            calls.append("activate \(bundleIdentifier)")
            return activatesApp
        }
    }

    private let link = URL(string: "vscode://anthropic.claude-code/open?session=9eb4895f-b5d9-41d0-8161-864ac0eecf46&windowId=1")!
    private var recorder: Recorder!

    override func setUp() {
        super.setUp()
        recorder = Recorder()
    }

    private func attempt(_ plan: RoutePlan) -> RouteOutcome {
        RouteExecutor(actions: recorder).attempt(plan)
    }

    func testTheDeepLinkIsTriedFirstAndAloneWhenItOpens() {
        let outcome = attempt(RoutePlan(url: link, activateBundleIdentifier: "com.microsoft.VSCode", summary: "s"))

        XCTAssertEqual(outcome, .openedURL(link))
        XCTAssertEqual(recorder.calls, ["open \(link.absoluteString)"])
    }

    func testTheAppIsActivatedWhenTheLinkCannotBeOpened() {
        recorder.opens = false

        let outcome = attempt(RoutePlan(url: link, activateBundleIdentifier: "com.microsoft.VSCode", summary: "s"))

        XCTAssertEqual(outcome, .activatedApp("com.microsoft.VSCode"))
        XCTAssertEqual(recorder.calls, ["open \(link.absoluteString)", "activate com.microsoft.VSCode"])
    }

    func testATerminalSessionActivatesItsProcess() {
        XCTAssertEqual(attempt(RoutePlan(activatePid: 812, summary: "s")), .activatedProcess(812))
        XCTAssertEqual(recorder.calls, ["activate pid 812"])
    }

    func testAnEmptyPlanOrEveryStepFailingIsAFailure() {
        XCTAssertEqual(attempt(RoutePlan(summary: "Nothing to route to")), .failed("nothing to open or activate"))
        XCTAssertTrue(recorder.calls.isEmpty)

        recorder.opens = false
        recorder.activatesPid = false
        recorder.activatesApp = false
        let outcome = attempt(RoutePlan(url: link, activatePid: 9, activateBundleIdentifier: "x.y", summary: "s"))
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(recorder.calls.count, 3, "every fallback was tried")
    }
}
