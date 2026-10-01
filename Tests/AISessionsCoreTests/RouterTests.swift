import XCTest
@testable import AISessionsCore

final class RouterTests: XCTestCase {
    private let claudeId = "9eb4895f-b5d9-41d0-8161-864ac0eecf46"
    private let threadId = "019a8b2c-1d2e-7f30-8a4b-5c6d7e8f9a0b"
    private var tmp: URL!
    private var logsRoot: URL { tmp.appendingPathComponent("logs", isDirectory: true) }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: Fixtures

    private func session(_ agent: Agent, id: String? = nil, host: SessionHost,
                         entrypoint: String? = nil, pid: Int32? = nil) -> TrackedSession {
        let epoch = Date(timeIntervalSince1970: 0)
        return TrackedSession(
            key: SessionKey(agent: agent, id: id ?? (agent == .claude ? claudeId : threadId)),
            title: "title", project: "project", state: .idle, pid: pid, entrypoint: entrypoint,
            host: host, firstSeen: epoch, lastChange: epoch)
    }

    private func started(_ pid: Int32) -> String {
        "2099-01-01 10:07:03.416 [info] Extension host with pid \(pid) started\n"
    }

    @discardableResult
    private func writeLog(_ text: String, window: Int) throws -> URL {
        let dir = logsRoot.appendingPathComponent("20990101T000000/window\(window)/exthost", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("exthost.log")
        try Data(text.utf8).write(to: file)
        return file
    }

    private func spawnSleep(stdin: URL? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        if let stdin { process.standardInput = try FileHandle(forReadingFrom: stdin) }
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }

    /// Stand-ins for an extension host must live in an app bundle, as xctest does in Xcode.app.
    private func skipUnlessRunnerIsInAnAppBundle() throws {
        try XCTSkipUnless(ProcessKit.path(getpid())?.contains(".app/") == true, "test runner is not inside an app bundle")
    }

    // MARK: Deep links

    func testClaudeDeepLinkExactStrings() {
        XCTAssertEqual(Router.claudeDeepLink(sessionId: claudeId, windowId: 1, scheme: "vscode")?.absoluteString,
                       "vscode://anthropic.claude-code/open?session=9eb4895f-b5d9-41d0-8161-864ac0eecf46&windowId=1")
        XCTAssertEqual(Router.claudeDeepLink(sessionId: claudeId, windowId: nil, scheme: "vscode")?.absoluteString,
                       "vscode://anthropic.claude-code/open?session=9eb4895f-b5d9-41d0-8161-864ac0eecf46")
        XCTAssertEqual(Router.claudeDeepLink(sessionId: claudeId, windowId: 0, scheme: "vscode")?.absoluteString,
                       "vscode://anthropic.claude-code/open?session=9eb4895f-b5d9-41d0-8161-864ac0eecf46")
        XCTAssertEqual(Router.claudeDeepLink(sessionId: claudeId, windowId: 12, scheme: "vscode-insiders")?.absoluteString,
                       "vscode-insiders://anthropic.claude-code/open?session=9eb4895f-b5d9-41d0-8161-864ac0eecf46&windowId=12")
    }

    func testClaudeDeepLinkRejectsNonUUIDs() {
        for bad in ["coreos-e1", "", "9eb4895f-b5d9-41d0-8161-864ac0eecf4",
                    "9eb4895f-b5d9-41d0-8161-864ac0eecf46&windowId=9", "../9eb4895f-b5d9-41d0-8161-864ac0eecf46"] {
            XCTAssertNil(Router.claudeDeepLink(sessionId: bad, windowId: 1, scheme: "vscode"), bad)
        }
        XCTAssertNil(Router.claudeDeepLink(sessionId: claudeId, windowId: 1, scheme: "not a scheme"))
    }

    func testCodexDeepLinkExactStrings() {
        XCTAssertEqual(Router.codexDeepLink(threadId: threadId, windowId: nil, scheme: "vscode")?.absoluteString,
                       "vscode://openai.chatgpt/local/019a8b2c-1d2e-7f30-8a4b-5c6d7e8f9a0b")
        XCTAssertEqual(Router.codexDeepLink(threadId: threadId, windowId: 2, scheme: "vscode")?.absoluteString,
                       "vscode://openai.chatgpt/local/019a8b2c-1d2e-7f30-8a4b-5c6d7e8f9a0b?windowId=2")
        XCTAssertEqual(Router.codexDeepLink(threadId: "deadbeef", windowId: nil, scheme: "cursor")?.absoluteString,
                       "cursor://openai.chatgpt/local/deadbeef")
    }

    func testCodexDeepLinkRejectsIdsThatAreNotUUIDLike() {
        for bad in ["", "1234567", "019A8B2C-1D2E-7F30-8A4B-5C6D7E8F9A0B", "019a8b2c/../../x",
                    "019a8b2c 1d2e", "019a8b2c?windowId=1", "zzzzzzzz", String(repeating: "a", count: 65)] {
            XCTAssertNil(Router.codexDeepLink(threadId: bad, windowId: nil, scheme: "vscode"), bad)
        }
    }

    // MARK: Plans from resolved facts

    func testClaudeVSCodePlanCarriesTheWindowWheneverKnown() {
        let s = session(.claude, host: .vscode(extensionHostPid: 3819), entrypoint: "claude-vscode")
        let plan = Router.plan(for: s, family: .vscode, windowId: 1, liveWindows: 1)
        XCTAssertEqual(plan, RoutePlan(
            url: URL(string: "vscode://anthropic.claude-code/open?session=\(claudeId)&windowId=1"),
            activateBundleIdentifier: "com.microsoft.VSCode",
            summary: "Open Claude session in Visual Studio Code window 1"))

        let unknownWindow = Router.plan(for: s, family: .vscode, windowId: nil, liveWindows: 3)
        XCTAssertEqual(unknownWindow.url?.absoluteString, "vscode://anthropic.claude-code/open?session=\(claudeId)")
        XCTAssertEqual(unknownWindow.activateBundleIdentifier, "com.microsoft.VSCode")
        XCTAssertNil(unknownWindow.activatePid)
    }

    func testCodexPlanCarriesTheWindowOnlyWhenSeveralWindowsAreLive() {
        let s = session(.codex, host: .vscode(extensionHostPid: nil), entrypoint: "codex_vscode")
        let link = "vscode://openai.chatgpt/local/\(threadId)"
        XCTAssertEqual(Router.plan(for: s, family: .vscode, windowId: 2, liveWindows: 0).url?.absoluteString, link)
        XCTAssertEqual(Router.plan(for: s, family: .vscode, windowId: 2, liveWindows: 1).url?.absoluteString, link)
        XCTAssertEqual(Router.plan(for: s, family: .vscode, windowId: nil, liveWindows: 3).url?.absoluteString, link)

        let several = Router.plan(for: s, family: .vscode, windowId: 2, liveWindows: 2)
        XCTAssertEqual(several.url?.absoluteString, link + "?windowId=2")
        XCTAssertEqual(several.activateBundleIdentifier, "com.microsoft.VSCode")
        XCTAssertEqual(several.summary, "Open Codex thread in Visual Studio Code window 2")
    }

    func testCodexThreadFromTheExtensionOpensInTheEditorWithoutAKnownHost() {
        let plan = Router.plan(for: session(.codex, host: .unknown, entrypoint: "codex_vscode"),
                               family: .vscode, windowId: nil, liveWindows: 1)
        XCTAssertEqual(plan.url?.absoluteString, "vscode://openai.chatgpt/local/\(threadId)")
        XCTAssertEqual(plan.activateBundleIdentifier, "com.microsoft.VSCode")

        let cli = Router.plan(for: session(.codex, host: .terminal(appPid: 812), entrypoint: "codex_cli_rs"),
                              family: .vscode, windowId: nil, liveWindows: 1)
        XCTAssertEqual(cli, RoutePlan(activatePid: 812, summary: "Activate the terminal app (pid 812)"))
    }

    func testPlanUsesTheFamilySchemeAndBundle() {
        let plan = Router.plan(for: session(.claude, host: .vscode(extensionHostPid: 1)),
                               family: .cursor, windowId: 2, liveWindows: 2)
        XCTAssertEqual(plan.url?.absoluteString, "cursor://anthropic.claude-code/open?session=\(claudeId)&windowId=2")
        XCTAssertEqual(plan.activateBundleIdentifier, "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(plan.summary, "Open Claude session in Cursor window 2")
    }

    func testNonUUIDClaudeSessionFallsBackToActivatingTheEditor() {
        let plan = Router.plan(for: session(.claude, id: "coreos-e1", host: .vscode(extensionHostPid: 1)),
                               family: .vscode, windowId: 1, liveWindows: 1)
        XCTAssertNil(plan.url)
        XCTAssertNil(plan.activatePid)
        XCTAssertEqual(plan.activateBundleIdentifier, "com.microsoft.VSCode")
    }

    func testTerminalSessionActivatesItsApp() {
        let plan = Router.plan(for: session(.claude, host: .terminal(appPid: 4321), entrypoint: "cli"),
                               family: .vscode, windowId: 1, liveWindows: 2)
        XCTAssertEqual(plan, RoutePlan(activatePid: 4321, summary: "Activate the terminal app (pid 4321)"))

        let unknownApp = Router.plan(for: session(.claude, host: .terminal(appPid: nil), entrypoint: "cli"),
                                     family: .vscode, windowId: nil, liveWindows: 0)
        XCTAssertTrue(unknownApp.isEmpty)
        XCTAssertTrue(unknownApp.summary.hasPrefix("Nothing to route to"), unknownApp.summary)
    }

    func testUnknownHostActivatesVSCodeOnlyWhenTheEntrypointSaysVSCode() {
        let fromExtension = Router.plan(for: session(.claude, host: .unknown, entrypoint: "claude-vscode"),
                                        family: .vscode, windowId: nil, liveWindows: 0)
        XCTAssertNil(fromExtension.url)
        XCTAssertNil(fromExtension.activatePid)
        XCTAssertEqual(fromExtension.activateBundleIdentifier, "com.microsoft.VSCode")

        for entrypoint in ["sdk-cli", "cli", nil] {
            let plan = Router.plan(for: session(.claude, host: .unknown, entrypoint: entrypoint),
                                   family: .vscode, windowId: nil, liveWindows: 0)
            XCTAssertTrue(plan.isEmpty, "\(entrypoint ?? "nil")")
            XCTAssertTrue(plan.summary.hasPrefix("Nothing to route to"), plan.summary)
        }
    }

    // MARK: Plans with lookups (this process stands in for an extension host)

    func testLiveClaudeSessionLinksToTheWindowItsExtensionHostHolds() throws {
        let handle = try FileHandle(forReadingFrom: writeLog("x\n", window: 4))
        defer { try? handle.close() }
        let s = session(.claude, host: .vscode(extensionHostPid: getpid()), entrypoint: "claude-vscode")
        let plan = Router.plan(for: s, lookup: .init(logsRoot: logsRoot))
        XCTAssertEqual(plan.url?.absoluteString, "vscode://anthropic.claude-code/open?session=\(claudeId)&windowId=4")
        XCTAssertEqual(plan.activateBundleIdentifier, "com.microsoft.VSCode")
    }

    func testExtensionHostIsTheAgentsParentWhenTheSourceDidNotSay() throws {
        try skipUnlessRunnerIsInAnAppBundle()
        let handle = try FileHandle(forReadingFrom: writeLog("x\n", window: 5))
        defer { try? handle.close() }
        let claude = try spawnSleep()
        defer { stop(claude) }
        let s = session(.claude, host: .vscode(extensionHostPid: nil), pid: claude.processIdentifier)
        let plan = Router.plan(for: s, lookup: .init(logsRoot: logsRoot))
        XCTAssertEqual(plan.url?.absoluteString, "vscode://anthropic.claude-code/open?session=\(claudeId)&windowId=5")
    }

    func testLiveCodexLinkCarriesTheWindowOnlyOnceASecondWindowIsLive() throws {
        let handle = try FileHandle(forReadingFrom: writeLog(started(getpid()), window: 2))
        defer { try? handle.close() }
        let s = session(.codex, host: .vscode(extensionHostPid: getpid()), entrypoint: "codex_vscode")
        let link = "vscode://openai.chatgpt/local/\(threadId)"
        XCTAssertEqual(Router.plan(for: s, lookup: .init(logsRoot: logsRoot)).url?.absoluteString, link)
        try writeLog(started(getppid()), window: 1)
        XCTAssertEqual(Router.plan(for: s, lookup: .init(logsRoot: logsRoot)).url?.absoluteString, link + "?windowId=2")
    }

    func testCodexThreadIsTracedToItsWindowThroughTheAppServer() throws {
        try skipUnlessRunnerIsInAnAppBundle()
        // Two live windows: the parent process owns window 1, this process window 2,
        // and /bin/sleep plays window 2's codex app-server holding the rollout open.
        try writeLog(started(getppid()), window: 1)
        let handle = try FileHandle(forReadingFrom: writeLog(started(getpid()), window: 2))
        defer { try? handle.close() }
        let thread = "019a8b2c-1d2e-7f30-8a4b-" + UUID().uuidString.suffix(12).lowercased()
        let rollout = tmp.appendingPathComponent("rollout-2099-01-01T00-00-00-\(thread).jsonl")
        try Data("{}\n".utf8).write(to: rollout)
        let appServer = try spawnSleep(stdin: rollout)
        defer { stop(appServer) }

        let s = session(.codex, id: thread, host: .vscode(extensionHostPid: nil), entrypoint: "codex_vscode")
        let plan = Router.plan(for: s, lookup: .init(logsRoot: logsRoot, codexExecutableName: "sleep"))
        XCTAssertEqual(plan.url?.absoluteString, "vscode://openai.chatgpt/local/\(thread)?windowId=2")
    }
}
