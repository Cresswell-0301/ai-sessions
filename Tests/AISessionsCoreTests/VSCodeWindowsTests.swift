import XCTest
@testable import AISessionsCore

final class VSCodeWindowsTests: XCTestCase {
    private var tmp: URL!
    private var logsRoot: URL { tmp.appendingPathComponent("logs", isDirectory: true) }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSCodeWindowsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: Fixtures

    /// Pids above macOS's PID_MAX (99999) are never alive.
    private func deadPid(_ n: Int32 = 1) -> Int32 { 999_000 + n }

    private func started(_ pid: Int32) -> String {
        "2099-01-01 10:07:03.416 [info] Extension host with pid \(pid) started\n"
    }

    @discardableResult
    private func writeLog(_ text: String, session: String = "20990101T000000", window: Int) throws -> URL {
        let dir = logsRoot.appendingPathComponent("\(session)/window\(window)/exthost", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("exthost.log")
        try Data(text.utf8).write(to: file)
        return file
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func load() -> VSCodeWindowIndex {
        VSCodeWindowIndex.load(family: .vscode, logsRoot: logsRoot)
    }

    // MARK: Editor family

    func testFamilyFromRealBundlePaths() {
        let code = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let family = EditorFamily.forAppBundle(path: code)
        XCTAssertEqual(family, .vscode)
        XCTAssertEqual([family.urlScheme, family.appSupportName, family.bundleIdentifier],
                       ["vscode", "Code", "com.microsoft.VSCode"])

        let insiders = EditorFamily.forAppBundle(path: "/Applications/Visual Studio Code - Insiders.app/Contents/Frameworks/Code - Insiders Helper (Plugin).app/Contents/MacOS/Code - Insiders Helper (Plugin)")
        XCTAssertEqual([insiders.urlScheme, insiders.appSupportName, insiders.bundleIdentifier],
                       ["vscode-insiders", "Code - Insiders", "com.microsoft.VSCodeInsiders"])

        let cursor = EditorFamily.forAppBundle(path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
        XCTAssertEqual([cursor.urlScheme, cursor.appSupportName, cursor.bundleIdentifier],
                       ["cursor", "Cursor", "com.todesktop.230313mzl4w4u92"])

        let windsurf = EditorFamily.forAppBundle(path: "/Applications/Windsurf.app/Contents/Frameworks/Windsurf Helper (Plugin).app/Contents/MacOS/Windsurf Helper (Plugin)")
        XCTAssertEqual([windsurf.urlScheme, windsurf.appSupportName], ["windsurf", "Windsurf"])

        let codium = EditorFamily.forAppBundle(path: "/Applications/VSCodium.app/Contents/Frameworks/Codium Helper (Plugin).app/Contents/MacOS/Codium Helper (Plugin)")
        XCTAssertEqual([codium.urlScheme, codium.appSupportName, codium.bundleIdentifier],
                       ["vscodium", "VSCodium", "com.vscodium"])

        // The bundle path itself, and the outermost bundle deciding over a helper's name.
        XCTAssertEqual(EditorFamily.forAppBundle(path: "/Users/me/Applications/Cursor.app"), .cursor)
        XCTAssertEqual(EditorFamily.forAppBundle(path: "/Applications/Cursor.app/Contents/Frameworks/Code - Insiders Helper.app/Contents/MacOS/x"), .cursor)
        // Unknown apps and non-app executables default to VS Code.
        XCTAssertEqual(EditorFamily.forAppBundle(path: "/Applications/Xcode.app/Contents/MacOS/Xcode"), .vscode)
        XCTAssertEqual(EditorFamily.forAppBundle(path: "/bin/zsh"), .vscode)
    }

    // MARK: Parsers

    func testExtensionHostLogLastStartedLineWins() {
        // A reload: the new host starts, then the old one's exit is logged.
        let log = """
        2026-09-30 10:07:03.416 [info] Extension host with pid 3819 started
        2026-09-30 10:07:04.000 [info] Eager extensions activated
        2026-09-30 13:40:57.874 [info] Extension host with pid 50646 started
        2026-09-30 13:40:58.100 [info] Extension host with pid 3819 exiting with code 0

        """
        XCTAssertEqual(VSCodeWindowIndex.parseExtensionHostLog(log), 50646)
        // A line still being written does not count yet.
        XCTAssertEqual(VSCodeWindowIndex.parseExtensionHostLog(log + "2026-10-01 08:00:00.000 [info] Extension host with pid 7123"), 50646)
        XCTAssertNil(VSCodeWindowIndex.parseExtensionHostLog("2026-10-01 07:14:56.722 [info] Extension host with pid 50646 exiting with code 0\n"))
        XCTAssertNil(VSCodeWindowIndex.parseExtensionHostLog("Extension host with pid 99999999999 started\n"))
        XCTAssertNil(VSCodeWindowIndex.parseExtensionHostLog(""))
    }

    func testWindowIdFromOpenPath() {
        let session = "/Users/nexflo/Library/Application Support/Code/logs/20260930T100702"
        XCTAssertEqual(VSCodeWindowIndex.windowId(fromOpenPath: session + "/window1/exthost/exthost.log"), 1)
        XCTAssertEqual(VSCodeWindowIndex.windowId(fromOpenPath: session + "/window12/exthost/Anthropic.claude-code/Claude Code.log"), 12)
        XCTAssertNil(VSCodeWindowIndex.windowId(fromOpenPath: session + "/window1/renderer.log"))
        XCTAssertNil(VSCodeWindowIndex.windowId(fromOpenPath: session + "/ptyhost.log"))
        XCTAssertNil(VSCodeWindowIndex.windowId(fromOpenPath: session + "/windowX/exthost/exthost.log"))
        XCTAssertNil(VSCodeWindowIndex.windowId(fromOpenPath: session + "/window1/exthost"))
        XCTAssertNil(VSCodeWindowIndex.windowId(fromOpenPath: "/tmp/logs/window1/exthost/exthost.log"))
        XCTAssertNil(VSCodeWindowIndex.windowId(fromOpenPath: "/tmp/catalogs/20260930T100702/window1/exthost/exthost.log"))
    }

    // MARK: Open files (libproc)

    func testOpenFileScanFindsTheWindowLogThisProcessHolds() throws {
        // This process stands in for an extension host holding its window's log
        // open. The log names no pid, so only the open-file scan can answer.
        let log = try writeLog("2099-01-01 10:07:03.416 [info] nothing to see\n", window: 7)
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        XCTAssertEqual(VSCodeWindowIndex.windowId(forExtensionHostPid: getpid(), family: .vscode, logsRoot: logsRoot), 7)
    }

    func testOpenFileScanFollowsTheLogHeldNow() throws {
        let lookup = { VSCodeWindowIndex.windowId(forExtensionHostPid: getpid(), family: .vscode, logsRoot: self.logsRoot) }
        let first = try FileHandle(forReadingFrom: writeLog("x\n", window: 7))
        XCTAssertEqual(lookup(), 7)
        try first.close()
        // The descriptor number may be reused for a different window's log.
        let second = try FileHandle(forReadingFrom: writeLog("x\n", session: "20990101T000001", window: 3))
        XCTAssertEqual(lookup(), 3)
        try second.close()
        XCTAssertNil(lookup())
    }

    // MARK: Logs

    func testLogsMapAnExtensionHostToItsWindow() throws {
        try writeLog(started(deadPid(1)), window: 1)
        try writeLog(started(deadPid(9)) + started(deadPid(3)) + "2099-01-01 10:08:00.000 [info] noise\n", window: 3)
        // Dead pids: the open-file scan finds nothing, so the answer comes from the logs.
        XCTAssertEqual(VSCodeWindowIndex.windowId(forExtensionHostPid: deadPid(3), family: .vscode, logsRoot: logsRoot), 3)
        XCTAssertNil(VSCodeWindowIndex.windowId(forExtensionHostPid: deadPid(9), family: .vscode, logsRoot: logsRoot))
        XCTAssertNil(VSCodeWindowIndex.windowId(forExtensionHostPid: deadPid(5), family: .vscode, logsRoot: logsRoot))
    }

    func testOnlyTheNewestThreeSessionDirsAreRead() throws {
        try writeLog(started(deadPid(4)), session: "20990101T000004", window: 1)
        try writeLog(started(deadPid(3)), session: "20990101T000003", window: 2)
        try writeLog(started(deadPid(2)), session: "20990101T000002", window: 1)
        try writeLog(started(deadPid(1)), session: "20990101T000001", window: 1)
        // Not session dirs, though they sort after the real ones.
        try writeLog(started(deadPid(8)), session: "zz-not-a-session", window: 1)
        try writeLog(started(deadPid(7)), session: "20990101T0000099", window: 1)

        let index = load()
        XCTAssertEqual(index.windows, [
            .init(id: 1, extensionHostPid: deadPid(4), sessionDir: "20990101T000004"),
            .init(id: 2, extensionHostPid: deadPid(3), sessionDir: "20990101T000003"),
            .init(id: 1, extensionHostPid: deadPid(2), sessionDir: "20990101T000002"),
        ])
        XCTAssertNil(index.windowId(forExtensionHostPid: deadPid(1)))
    }

    func testLogChangesAreFollowedIncrementally() throws {
        let log = try writeLog(started(deadPid(1)), window: 1)
        XCTAssertEqual(load().windows.first?.extensionHostPid, deadPid(1))
        try append("2099-01-01 10:08:00.000 [info] noise\n", to: log)
        XCTAssertEqual(load().windows.first?.extensionHostPid, deadPid(1))
        try append(started(deadPid(2)), to: log)
        XCTAssertEqual(load().windows.first?.extensionHostPid, deadPid(2))
        // A half-written line is re-read once it is complete.
        try append("2099-01-01 10:09:00.000 [info] Extension host with pid \(deadPid(3))", to: log)
        XCTAssertEqual(load().windows.first?.extensionHostPid, deadPid(2))
        try append(" started\n", to: log)
        XCTAssertEqual(load().windows.first?.extensionHostPid, deadPid(3))
        // Replaced by a shorter file: read afresh, not from the old offset.
        try Data(started(deadPid(4)).utf8).write(to: log, options: .atomic)
        XCTAssertEqual(load().windows.first?.extensionHostPid, deadPid(4))
    }

    func testOnlyTheLastTwoMegabytesOfALogAreRead() throws {
        let filler = String(repeating: "2099-01-01 10:08:00.000 [info] filler to push the first line out of reach\n", count: 30_000)
        XCTAssertGreaterThan(filler.utf8.count, 2 << 20)
        try writeLog(started(deadPid(1)) + filler, window: 1)
        try writeLog(started(deadPid(1)) + filler + started(deadPid(2)), window: 2)
        let index = load()
        XCTAssertNil(index.windowId(forExtensionHostPid: deadPid(1)))
        XCTAssertEqual(index.windowId(forExtensionHostPid: deadPid(2)), 2)
    }

    // MARK: Live windows

    func testLiveWindowCountCountsWindowsWhoseLatestHostIsAlive() throws {
        let session = "20990101T000002"
        try writeLog(started(deadPid(1)) + started(getpid()), session: session, window: 1)
        try writeLog(started(getppid()), session: session, window: 2)
        try writeLog(started(getpid()) + started(deadPid(2)), session: session, window: 3)
        // A `code` CLI launch leaves a newer session dir with no windows.
        try FileManager.default.createDirectory(
            at: logsRoot.appendingPathComponent("20990101T000003"), withIntermediateDirectories: true)
        XCTAssertEqual(VSCodeWindowIndex.liveWindowCount(family: .vscode, logsRoot: logsRoot), 2)
        XCTAssertEqual(VSCodeWindowIndex.liveWindowCount(family: .vscode, logsRoot: tmp.appendingPathComponent("missing")), 0)
    }

    func testLiveWindowsComeFromTheNewestLaunchWithALiveWindow() {
        let index = VSCodeWindowIndex(windows: [
            .init(id: 1, extensionHostPid: 10, sessionDir: "20990101T000003"),
            .init(id: 1, extensionHostPid: 20, sessionDir: "20990101T000002"),
            .init(id: 2, extensionHostPid: 21, sessionDir: "20990101T000002"),
            .init(id: 1, extensionHostPid: 30, sessionDir: "20990101T000001"),
        ])
        // A live-looking pid in an older launch is a reused pid, not a window.
        XCTAssertEqual(index.liveWindows(isAlive: { [20, 21, 30].contains($0) }).map(\.extensionHostPid), [20, 21])
        XCTAssertEqual(index.liveWindows(isAlive: { $0 == 30 }).map(\.extensionHostPid), [30])
        XCTAssertEqual(index.liveWindows(isAlive: { _ in false }), [])
    }

    // MARK: Codex app-server

    func testCodexScanFindsTheAppServerHoldingTheRolloutOpen() throws {
        // This process plays the extension host (it must live in an app bundle,
        // as xctest does inside Xcode.app) and /bin/sleep its codex app-server.
        try XCTSkipUnless(ProcessKit.path(getpid())?.contains(".app/") == true, "test runner is not inside an app bundle")
        let thread = "019a8b2c-1d2e-7f30-8a4b-" + UUID().uuidString.suffix(12).lowercased()
        let rollout = tmp.appendingPathComponent("sessions/2099/01/01/rollout-2099-01-01T00-00-00-\(thread).jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: rollout)

        let appServer = Process()
        appServer.executableURL = URL(fileURLWithPath: "/bin/sleep")
        appServer.arguments = ["30"]
        appServer.standardInput = try FileHandle(forReadingFrom: rollout)
        try appServer.run()
        defer {
            appServer.terminate()
            appServer.waitUntilExit()
        }

        XCTAssertEqual(VSCodeWindowIndex.codexExtensionHostPid(threadId: thread, executableName: "sleep"), getpid())
        XCTAssertNil(VSCodeWindowIndex.codexExtensionHostPid(threadId: "019a8b2c-0000-7000-8000-000000000000", executableName: "sleep"))
        XCTAssertNil(VSCodeWindowIndex.codexExtensionHostPid(threadId: thread))
    }
}
