import XCTest
@testable import AISessionsCore

/// Fixtures shared by the Claude source tests. Everything is written to a
/// fresh temp directory; nothing reads the real ~/.claude.
enum ClaudeFixtures {
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sessions-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Unlinking a 000 file only needs its directory writable, so this works
    /// for the permission tests too.
    static func removeTree(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// `procStart` exactly as Claude writes it: asctime layout, UTC, the day
    /// padded with a space ("Thu Oct  1 02:59:07 2026").
    static func asctimeUTC(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.weekday, .month, .day, .hour, .minute, .second, .year], from: date)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "%@ %@ %2d %02d:%02d:%02d %d", weekdays[c.weekday! - 1], months[c.month! - 1],
                      c.day!, c.hour!, c.minute!, c.second!, c.year!)
    }

    static var ownStartTime: Date { ProcessKit.info(getpid())!.startTime }
    static var ownProcStart: String { asctimeUTC(ownStartTime) }

    /// A pid that belonged to a process a moment ago and now belongs to none.
    static func deadPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(2)
        while ProcessKit.isAlive(pid), Date() < deadline { usleep(10_000) }
        return pid
    }

    // MARK: Registry records

    /// A record shaped like the one in DESIGN.md.
    static func recordData(pid: Int32, sessionId: String, status: String, updatedAt: Double,
                           procStart: String?, entrypoint: String = "claude-vscode",
                           kind: String = "interactive", name: String? = nil,
                           cwd: String = "/work/demo-app") -> Data {
        var record: [String: Any] = [
            "pid": pid, "sessionId": sessionId, "cwd": cwd, "startedAt": updatedAt - 60_000,
            "version": "2.1.284", "peerProtocol": 1, "kind": kind, "entrypoint": entrypoint,
            "pidDomain": "darwin", "status": status, "updatedAt": updatedAt, "statusUpdatedAt": updatedAt,
        ]
        record["procStart"] = procStart
        record["name"] = name
        return try! JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
    }

    // MARK: Transcript lines

    static func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    static func lines(_ objects: [[String: Any]]) -> Data {
        objects.reduce(into: Data()) { $0.append(line($1)) }
    }

    static func customTitle(_ title: String, session: String) -> [String: Any] {
        ["type": "custom-title", "customTitle": title, "sessionId": session]
    }

    static func aiTitle(_ title: String, session: String) -> [String: Any] {
        ["type": "ai-title", "aiTitle": title, "sessionId": session]
    }

    static func lastPrompt(_ prompt: String, session: String) -> [String: Any] {
        ["type": "last-prompt", "lastPrompt": prompt, "leafUuid": UUID().uuidString, "sessionId": session]
    }

    static func assistant(_ texts: [String], session: String, sidechain: Bool = false) -> [String: Any] {
        assistant(content: texts.map { ["type": "text", "text": $0] }, session: session, sidechain: sidechain)
    }

    static func assistant(content: [[String: Any]], session: String, sidechain: Bool = false) -> [String: Any] {
        [
            "type": "assistant", "isSidechain": sidechain, "sessionId": session, "uuid": UUID().uuidString,
            "message": [
                "id": "msg_test", "type": "message", "role": "assistant", "model": "claude-test",
                "stop_reason": "end_turn", "content": content,
            ] as [String: Any],
        ]
    }

    static func toolUse(session: String) -> [String: Any] {
        assistant(content: [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]]],
                  session: session)
    }

    static func user(_ text: String, session: String) -> [String: Any] {
        ["type": "user", "sessionId": session, "message": ["role": "user", "content": text] as [String: Any]]
    }

    /// One tool-result line of exactly `bytes` bytes, newline included. It
    /// matches no entry kind the reader looks for.
    static func fillerLine(bytes: Int, session: String) -> Data {
        func make(_ count: Int) -> Data {
            line([
                "type": "user", "sessionId": session,
                "message": [
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": "toolu_1",
                                 "content": String(repeating: "x", count: count)]],
                ] as [String: Any],
            ])
        }
        let overhead = make(0).count
        precondition(bytes >= overhead, "a filler line needs at least \(overhead) bytes")
        return make(bytes - overhead)
    }

    /// Filler lines adding up to exactly `totalBytes`.
    static func filler(totalBytes: Int, session: String) -> Data {
        var data = Data()
        while totalBytes - data.count > 16_384 { data.append(fillerLine(bytes: 8_192, session: session)) }
        if totalBytes > data.count { data.append(fillerLine(bytes: totalBytes - data.count, session: session)) }
        return data
    }
}

final class ClaudeRegistryTests: XCTestCase {
    /// Verbatim from DESIGN.md (observed on this machine).
    static let designRecord = """
    {"pid":48433,"sessionId":"9eb4895f-b5d9-41d0-8161-864ac0eecf46","cwd":"/Users/nexflo/coreOS",
     "startedAt":1790823548541,"procStart":"Thu Oct  1 02:59:07 2026","version":"2.1.284",
     "peerProtocol":1,"peerFeatures":["notify_idle"],"kind":"interactive","entrypoint":"claude-vscode",
     "pidDomain":"darwin","messagingSocketPath":"/tmp/cc-socks/48433.sock","name":"coreos-e1",
     "nameSource":"derived","nameSince":1790823548541,"status":"busy",
     "updatedAt":1790823673821,"statusUpdatedAt":1790823673821}
    """

    private func parse(_ json: String) -> ClaudeRegistryRecord? {
        ClaudeRegistry.parse(Data(json.utf8))
    }

    func testParsesTheRecordFromTheDesignNotes() throws {
        let record = try XCTUnwrap(parse(Self.designRecord))
        XCTAssertEqual(record, ClaudeRegistryRecord(
            pid: 48433, sessionId: "9eb4895f-b5d9-41d0-8161-864ac0eecf46", cwd: "/Users/nexflo/coreOS",
            startedAt: 1790823548541, procStart: "Thu Oct  1 02:59:07 2026", kind: "interactive",
            entrypoint: "claude-vscode", name: "coreos-e1", status: "busy",
            updatedAt: 1790823673821, statusUpdatedAt: 1790823673821))
        XCTAssertEqual(record.stateSince, Date(timeIntervalSince1970: 1790823673.821))
        XCTAssertEqual(ClaudeRegistry.activityState(status: record.status), .running)
        XCTAssertTrue(ClaudeRegistry.isInteractive(kind: record.kind, entrypoint: record.entrypoint))
    }

    func testStateSinceFallsBackFromStatusTimeToUpdateToStart() {
        var record = ClaudeRegistryRecord(pid: 1, sessionId: "s", startedAt: 1_000, updatedAt: 2_000, statusUpdatedAt: 3_000)
        XCTAssertEqual(record.stateSince, Date(timeIntervalSince1970: 3))
        record.statusUpdatedAt = nil
        XCTAssertEqual(record.stateSince, Date(timeIntervalSince1970: 2))
        record.updatedAt = nil
        XCTAssertEqual(record.stateSince, Date(timeIntervalSince1970: 1))
        record.startedAt = nil
        XCTAssertNil(record.stateSince)
    }

    func testParseRejectsHalfWrittenAndImplausibleRecords() throws {
        let full = Data(Self.designRecord.utf8)
        for cut in [0, 1, 40, full.count / 2, full.count - 1] {
            XCTAssertNil(ClaudeRegistry.parse(full.prefix(cut)), "a record cut at byte \(cut) must not parse")
        }
        XCTAssertNil(parse(#"{"sessionId":"abc"}"#), "no pid")
        XCTAssertNil(parse(#"{"pid":0,"sessionId":"abc"}"#), "pid 0")
        XCTAssertNil(parse(#"{"pid":12,"sessionId":""}"#), "empty session id")
        XCTAssertNil(parse(#"{"pid":12,"sessionId":"../../../etc/passwd"}"#), "a session id that is a path")
        XCTAssertNil(parse("[1,2]"))

        // One field changing type in a future release does not hide the session.
        let odd = try XCTUnwrap(parse(#"{"pid":12,"sessionId":"abc-1","name":7,"startedAt":"soon","status":"idle"}"#))
        XCTAssertNil(odd.name)
        XCTAssertNil(odd.startedAt)
        XCTAssertEqual(odd.status, "idle")
    }

    func testRecordsListsOnlyPidJSONFilesAndSkipsTheKeys() throws {
        let dir = try ClaudeFixtures.makeTempDir()
        defer { ClaudeFixtures.removeTree(dir) }
        let names = ["48433.json", "7.json", "48433.0a1b2c3d4e5f6789.key", "abc.json", "12a.json",
                     "48433.json.tmp", ".5.json", "0.json", "99999999999.json", "-3.json", "\u{0661}\u{0662}.json"]
        for name in names { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: dir.appendingPathComponent("48433.0a1b2c3d4e5f6789.key").path)

        XCTAssertEqual(ClaudeRegistry.records(in: dir).map(\.lastPathComponent), ["7.json", "48433.json"])
        XCTAssertEqual(ClaudeRegistry.records(in: dir.appendingPathComponent("missing")), [])
    }

    func testOwnProcessIsLiveOnlyWithItsOwnStartTime() {
        var record = ClaudeRegistryRecord(pid: getpid(), sessionId: "s1", procStart: ClaudeFixtures.ownProcStart)
        XCTAssertTrue(ClaudeRegistry.isLive(record), "own pid with its own asctime start time")

        record.procStart = "Mon Jan  1 00:00:00 2001"
        XCTAssertFalse(ClaudeRegistry.isLive(record), "same pid, another start time: a stale record of a reused pid")

        record.procStart = ClaudeFixtures.asctimeUTC(ClaudeFixtures.ownStartTime.addingTimeInterval(60))
        XCTAssertFalse(ClaudeRegistry.isLive(record), "a minute off is another process")
    }

    func testStartedAtWindowStandsInForAMissingProcStart() {
        let start = ClaudeFixtures.ownStartTime.timeIntervalSince1970 * 1000
        var record = ClaudeRegistryRecord(pid: getpid(), sessionId: "s1")
        XCTAssertTrue(ClaudeRegistry.isLive(record), "nothing to compare: plain liveness")
        record.startedAt = start + 5_000
        XCTAssertTrue(ClaudeRegistry.isLive(record))
        record.startedAt = start + 119_000
        XCTAssertTrue(ClaudeRegistry.isLive(record))
        record.startedAt = start + 600_000
        XCTAssertFalse(ClaudeRegistry.isLive(record), "written ten minutes after this process started")
        record.startedAt = start - 60_000
        XCTAssertFalse(ClaudeRegistry.isLive(record), "written before this process existed")
    }

    func testDeadPidIsNotLive() throws {
        let pid = try ClaudeFixtures.deadPid()
        XCTAssertFalse(ProcessKit.isAlive(pid), "precondition: the child exited and was reaped")
        let record = ClaudeRegistryRecord(pid: pid, sessionId: "s1", procStart: ClaudeFixtures.ownProcStart)
        XCTAssertFalse(ClaudeRegistry.isLive(record))
        XCTAssertNil(ClaudeRegistry.startMatches(record), "no process, no verdict")
    }

    func testActivityStateMirrorsTheExtension() {
        XCTAssertEqual(ClaudeRegistry.activityState(status: "busy"), .running)
        XCTAssertEqual(ClaudeRegistry.activityState(status: "waiting"), .waiting)
        XCTAssertEqual(ClaudeRegistry.activityState(status: "idle"), .idle)
        XCTAssertEqual(ClaudeRegistry.activityState(status: nil), .idle)
        XCTAssertEqual(ClaudeRegistry.activityState(status: "compacting"), .idle, "unknown future values are idle")
    }

    func testInteractiveClassificationMirrorsTheExtension() {
        let table: [(kind: String?, entrypoint: String?, interactive: Bool)] = [
            ("interactive", "cli", true),
            ("interactive", "claude-vscode", true),
            ("interactive", "claude-desktop", true),
            ("interactive", "claude-desktop-3p", true),
            (nil, "claude-vscode", true),
            ("interactive", "sdk-cli", false),
            ("interactive", "sdk-ts", false),
            ("interactive", "sdk-py", false),
            ("interactive", "mcp", false),
            ("interactive", "local-agent", false),
            ("interactive", "claude-code-github-action", false),
            ("interactive", nil, false),
            ("background", "cli", false),
            ("subagent", "claude-vscode", false),
        ]
        for row in table {
            XCTAssertEqual(ClaudeRegistry.isInteractive(kind: row.kind, entrypoint: row.entrypoint), row.interactive,
                           "kind \(row.kind ?? "nil"), entrypoint \(row.entrypoint ?? "nil")")
        }
    }

    func testHostOfAVSCodeSessionIsItsParentProcess() throws {
        let parent = try XCTUnwrap(ProcessKit.info(getpid())).ppid
        let vscode = ClaudeRegistryRecord(pid: getpid(), sessionId: "s1", entrypoint: "claude-vscode")
        XCTAssertEqual(ClaudeRegistry.host(for: vscode), .vscode(extensionHostPid: parent > 1 ? parent : nil))

        let gone = ClaudeRegistryRecord(pid: try ClaudeFixtures.deadPid(), sessionId: "s1", entrypoint: "claude-vscode")
        XCTAssertEqual(ClaudeRegistry.host(for: gone), .vscode(extensionHostPid: nil))

        for entrypoint in ["sdk-ts", "claude-desktop", "mcp"] {
            let record = ClaudeRegistryRecord(pid: getpid(), sessionId: "s1", entrypoint: entrypoint)
            XCTAssertEqual(ClaudeRegistry.host(for: record), .unknown, entrypoint)
        }

        let cli = ClaudeRegistryRecord(pid: getpid(), sessionId: "s1", entrypoint: "cli")
        guard case .terminal = ClaudeRegistry.host(for: cli) else {
            return XCTFail("a cli session is hosted by a terminal")
        }
    }

    func testTerminalHostIsTheNearestAppAncestor() {
        func process(_ pid: Int32, parent: Int32) -> ProcInfo {
            ProcInfo(pid: pid, ppid: parent, startTime: Date(), comm: "")
        }
        let paths: [Int32: String] = [
            10: "/bin/zsh",
            11: "/usr/bin/login",
            12: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            20: "/bin/zsh",
            21: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
            22: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            30: "/bin/zsh",
            31: "/opt/homebrew/bin/tmux",
            41: "/Applications/Odd.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
        ]
        let path: (Int32) -> String? = { paths[$0] }

        let terminal = [process(10, parent: 11), process(11, parent: 12), process(12, parent: 1)]
        XCTAssertEqual(ClaudeRegistry.terminalAppPid(ancestors: terminal, path: path), 12)

        let vscodeTerminal = [process(20, parent: 21), process(21, parent: 22), process(22, parent: 1)]
        XCTAssertEqual(ClaudeRegistry.terminalAppPid(ancestors: vscodeTerminal, path: path), 22,
                       "a helper resolves to its app's own process")

        let tmux = [process(30, parent: 31), process(31, parent: 1)]
        XCTAssertNil(ClaudeRegistry.terminalAppPid(ancestors: tmux, path: path), "no app above a tmux server")

        let orphanHelper = [process(41, parent: 1)]
        XCTAssertEqual(ClaudeRegistry.terminalAppPid(ancestors: orphanHelper, path: path), 41,
                       "a helper whose app is not an ancestor is still the nearest app process")
    }
}
