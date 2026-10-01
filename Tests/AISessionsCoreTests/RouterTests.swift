import XCTest
@testable import AISessionsCore

final class RouterTests: XCTestCase {
    private let claudeId = "9eb4895f-b5d9-41d0-8161-864ac0eecf46"
    private let threadId = "019a8b2c-1d2e-7f30-8a4b-5c6d7e8f9a0b"
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var tmp: URL!
    private var savedHome: String?
    private var logsRoot: URL { tmp.appendingPathComponent("logs", isDirectory: true) }

    /// Log.shared writes under AppPaths.home: a fresh home per test keeps the
    /// router's warnings off the real ~/.ai-sessions and lets a test read them.
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        setenv("AI_SESSIONS_HOME", tmp.appendingPathComponent("home").path, 1)
    }

    override func tearDownWithError() throws {
        Log.shared.flush()
        if let savedHome { setenv("AI_SESSIONS_HOME", savedHome, 1) } else { unsetenv("AI_SESSIONS_HOME") }
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

    /// A newer session dir with no windows, as a `code <path>` launch leaves.
    private func cliLaunch(_ n: Int) throws {
        let dir = logsRoot.appendingPathComponent(String(format: "20990101T0010%02d", n), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("2099-01-01 10:10:00.000 [info] Sending env to running instance...\n".utf8)
            .write(to: dir.appendingPathComponent("main.log"))
    }

    private func loggedText() -> String {
        Log.shared.flush()
        return (try? String(contentsOf: Log.shared.fileURL, encoding: .utf8)) ?? ""
    }

    /// An Electron editor bundle under tmp; returns its extension host's path.
    private func makeBundle(_ name: String, bundleIdentifier: String, product: [String: String]?) throws -> String {
        try EditorBundleFixture.make(in: tmp, name, bundleIdentifier: bundleIdentifier, product: product)
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

    func testUnknownForkIsDeepLinkedWithItsOwnSchemeNotVSCodes() throws {
        // A Claude tab in an Antigravity window 2 (its exthost.log path names window2).
        let helper = try makeBundle("Antigravity", bundleIdentifier: "com.google.antigravity",
                                    product: ["nameShort": "Antigravity", "urlProtocol": "antigravity"])
        let s = session(.claude, host: .vscode(extensionHostPid: 4242), entrypoint: "claude-vscode")
        let plan = Router.plan(for: s, family: EditorFamily.forAppBundle(path: helper), windowId: 2, liveWindows: 0)
        XCTAssertEqual(plan, RoutePlan(
            url: URL(string: "antigravity://anthropic.claude-code/open?session=\(claudeId)&windowId=2"),
            activateBundleIdentifier: "com.google.antigravity",
            summary: "Open Claude session in Antigravity window 2"))
    }

    func testEditorWithoutADeepLinkSchemeIsOnlyBroughtToTheFront() throws {
        let helper = try makeBundle("Mystery Editor", bundleIdentifier: "com.example.mystery", product: nil)
        let family = EditorFamily.forAppBundle(path: helper)
        for s in [session(.claude, host: .vscode(extensionHostPid: 4242), entrypoint: "claude-vscode"),
                  session(.codex, host: .vscode(extensionHostPid: 4242), entrypoint: "codex_vscode")] {
            let plan = Router.plan(for: s, family: family, windowId: 2, liveWindows: 2)
            XCTAssertNil(plan.url, "\(s.key)")
            XCTAssertNil(plan.activatePid)
            XCTAssertEqual(plan.activateBundleIdentifier, "com.example.mystery")
            XCTAssertEqual(plan.summary, "Activate Mystery Editor: it has no known URL scheme to deep-link with")
        }
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

    func testCodexLinkKeepsItsWindowAfterCLILaunchesOfTheEditor() throws {
        // Two live windows: the parent process owns window 1, this process window 2.
        try writeLog(started(getppid()), window: 1)
        let handle = try FileHandle(forReadingFrom: writeLog(started(getpid()), window: 2))
        defer { try? handle.close() }
        // Three `code <path>` launches since VS Code started.
        for n in 1...3 { try cliLaunch(n) }
        let s = session(.codex, host: .vscode(extensionHostPid: getpid()), entrypoint: "codex_vscode")
        XCTAssertEqual(Router.plan(for: s, lookup: .init(logsRoot: logsRoot)).url?.absoluteString,
                       "vscode://openai.chatgpt/local/\(threadId)?windowId=2", "codex link")
    }

    // MARK: VS Code matches windowId as a prefix

    func testWindowIdsThatVSCodesUnanchoredMatchAlsoAccepts() {
        XCTAssertEqual(Router.confusableWindowIds(for: 1, among: [1, 2, 10, 12, 21, 100, 12]), [10, 12, 100])
        XCTAssertEqual(Router.confusableWindowIds(for: 2, among: [1, 2, 3, 12, 20, 29]), [20, 29])
        XCTAssertEqual(Router.confusableWindowIds(for: 12, among: [1, 2, 12, 112, 120]), [120])
        XCTAssertEqual(Router.confusableWindowIds(for: 3, among: []), [])
    }

    func testTheWindowIdALinkCarries() {
        XCTAssertEqual(Router.linkedWindowId(Router.claudeDeepLink(sessionId: claudeId, windowId: 12, scheme: "vscode")), 12)
        XCTAssertEqual(Router.linkedWindowId(Router.codexDeepLink(threadId: threadId, windowId: 3, scheme: "vscode")), 3)
        XCTAssertNil(Router.linkedWindowId(Router.claudeDeepLink(sessionId: claudeId, windowId: nil, scheme: "vscode")))
        XCTAssertNil(Router.linkedWindowId(nil))
    }

    func testLinkToAWindowWhoseIdPrefixesAnotherLiveWindowIsFlagged() throws {
        // Window 1 is this process (holding its log open), window 12 the parent:
        // VS Code tests /window:1/ against "window:12" too, first match wins.
        let handle = try FileHandle(forReadingFrom: writeLog(started(getpid()), window: 1))
        defer { try? handle.close() }
        try writeLog(started(getppid()), window: 12)
        let s = session(.claude, host: .vscode(extensionHostPid: getpid()), entrypoint: "claude-vscode")

        let plan = Router.plan(for: s, lookup: .init(logsRoot: logsRoot))
        XCTAssertEqual(plan.url?.absoluteString, "vscode://anthropic.claude-code/open?session=\(claudeId)&windowId=1",
                       "the link itself is unchanged")
        XCTAssertEqual(plan.summary, "Open Claude session in Visual Studio Code window 1"
            + "; warning: Visual Studio Code may deliver windowId=1 to window 12 (it matches window ids by prefix)")
        let log = loggedText()
        XCTAssertTrue(log.contains("WARN route claude:\(claudeId): Visual Studio Code may deliver windowId=1 to window 12"), log)
    }

    func testCodexLinkWithAWindowIsFlaggedToo() throws {
        let handle = try FileHandle(forReadingFrom: writeLog(started(getpid()), window: 2))
        defer { try? handle.close() }
        try writeLog(started(getppid()), window: 21)
        let s = session(.codex, host: .vscode(extensionHostPid: getpid()), entrypoint: "codex_vscode")
        let plan = Router.plan(for: s, lookup: .init(logsRoot: logsRoot))
        XCTAssertEqual(plan.url?.absoluteString, "vscode://openai.chatgpt/local/\(threadId)?windowId=2")
        XCTAssertTrue(plan.summary.hasSuffix("; warning: Visual Studio Code may deliver windowId=2 to window 21 (it matches window ids by prefix)"),
                      plan.summary)
    }

    func testNoWarningWhenNoOtherLiveWindowIdStartsWithTheTarget() throws {
        // Target 12 with a live window 1: /window:12/ never matches "window:1".
        let handle = try FileHandle(forReadingFrom: writeLog(started(getpid()), window: 12))
        defer { try? handle.close() }
        try writeLog(started(getppid()), window: 1)
        // A closed window 120 (dead extension host) has no connection to steal it.
        try writeLog(started(999_120), window: 120)
        let s = session(.claude, host: .vscode(extensionHostPid: getpid()), entrypoint: "claude-vscode")
        let plan = Router.plan(for: s, lookup: .init(logsRoot: logsRoot))
        XCTAssertEqual(plan.url?.absoluteString, "vscode://anthropic.claude-code/open?session=\(claudeId)&windowId=12")
        XCTAssertEqual(plan.summary, "Open Claude session in Visual Studio Code window 12")
        XCTAssertFalse(loggedText().contains("may deliver"))
    }

    // MARK: Docs

    /// Neither Anthropic nor OpenAI is in VS Code's trustedExtensionProtocolHandlers:
    /// both links ask once, unless the user pre-approves them.
    func testDocsDescribeTheOneTimeURIPromptForBothExtensions() throws {
        for name in ["README.md", "DESIGN.md"] {
            let text = try String(contentsOf: Self.packageRoot.appendingPathComponent(name), encoding: .utf8)
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertFalse(flat.contains("Codex has no such dialog"), name)
            XCTAssertFalse(flat.contains("trusted publisher: no dialog"), name)
            XCTAssertTrue(flat.contains(#""extensions.confirmedUriHandlerExtensionIds": ["anthropic.claude-code", "openai.chatgpt"]"#), name)
            XCTAssertTrue(flat.contains("Do not ask me again for this extension"), name)
            XCTAssertTrue(flat.contains("Claude sidebar"), "\(name): a sidebar session opens as an editor tab")
        }
    }
}
