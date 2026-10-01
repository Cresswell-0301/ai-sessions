import XCTest
@testable import AISessionsCore

/// Collects what `ClaudeSource` would have logged.
final class ClaudeLogSink {
    var lines: [String] = []
}

final class ClaudeSourceTests: XCTestCase {
    private typealias F = ClaudeFixtures
    private let session = "3f2c1b7a-1111-4222-8333-944455556666"
    /// Does not exist on disk, so the transcript lives under its plain encoding.
    private let cwd = "/work/demo-app"
    private var root: URL!
    private var configDir: URL!
    private var sessionsDir: URL!
    private var sink: ClaudeLogSink!

    override func setUpWithError() throws {
        root = try F.makeTempDir()
        configDir = root.appendingPathComponent("claude-config")
        sessionsDir = configDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        sink = ClaudeLogSink()
    }

    override func tearDown() {
        F.removeTree(root)
    }

    private var transcriptURL: URL {
        configDir.appendingPathComponent("projects/-work-demo-app/\(session).jsonl")
    }

    private func makeSource(configDirs: [URL]? = nil, probe: ClaudeProcessProbe = ClaudeProcessProbe()) -> ClaudeSource {
        let sink = sink!
        return ClaudeSource(configDirs: configDirs ?? [configDir], log: { sink.lines.append($0) }, probe: probe)
    }

    @discardableResult
    private func writeRecord(pid: Int32 = getpid(), sessionId: String? = nil, status: String, updatedAt: Double,
                             procStart: String? = F.ownProcStart, entrypoint: String = "claude-vscode",
                             name: String? = "demo-e1") throws -> URL {
        let url = sessionsDir.appendingPathComponent("\(pid).json")
        try F.recordData(pid: pid, sessionId: sessionId ?? session, status: status, updatedAt: updatedAt,
                         procStart: procStart, entrypoint: entrypoint, name: name, cwd: cwd).write(to: url)
        return url
    }

    private func appendTranscript(_ entries: [[String: Any]]) throws {
        let data = F.lines(entries)
        guard let handle = try? FileHandle(forWritingTo: transcriptURL) else {
            return try data.write(to: transcriptURL)
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: End to end, real process checks

    func testBusyThenIdleFlipIsObserved() throws {
        try appendTranscript([
            F.aiTitle("Demo work", session: session),
            F.lastPrompt("do the thing", session: session),
            F.assistant(["Working on it."], session: session),
        ])
        try writeRecord(status: "busy", updatedAt: 1_790_000_000_000)
        let source = makeSource()
        let t0 = Date()

        let running = try XCTUnwrap(source.poll(now: t0).first)
        XCTAssertEqual(running.key, SessionKey(agent: .claude, id: session))
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.rawStatus, "busy")
        XCTAssertEqual(running.stateSince, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(running.title, "Demo work")
        XCTAssertEqual(running.lastMessage, "Working on it.")
        XCTAssertEqual(running.cwd, cwd)
        XCTAssertEqual(running.pid, getpid())
        XCTAssertEqual(running.entrypoint, "claude-vscode")
        XCTAssertTrue(running.interactive)
        let parent = try XCTUnwrap(ProcessKit.info(getpid())).ppid
        XCTAssertEqual(running.host, .vscode(extensionHostPid: parent))

        // The turn ends as observed live: the final message, then the status flip.
        try appendTranscript([F.assistant(["All done: 3 files changed."], session: session)])
        try writeRecord(status: "idle", updatedAt: 1_790_000_060_000)
        let idle = source.poll(now: t0.addingTimeInterval(1))
        XCTAssertEqual(idle.map(\.state), [.idle])
        XCTAssertEqual(idle.first?.rawStatus, "idle")
        XCTAssertEqual(idle.first?.stateSince, Date(timeIntervalSince1970: 1_790_000_060))
        XCTAssertEqual(idle.first?.lastMessage, "All done: 3 files changed.",
                       "a status flip re-reads the transcript at once, not after 5 s")

        try writeRecord(status: "waiting", updatedAt: 1_790_000_090_000)
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(2)).map(\.state), [.waiting])
        XCTAssertEqual(sink.lines, [])
    }

    func testDeletedRecordEndsTheSession() throws {
        let url = try writeRecord(status: "idle", updatedAt: 1_790_000_000_000)
        let source = makeSource()
        XCTAssertEqual(source.poll(now: Date()).count, 1)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(source.poll(now: Date()), [])
        XCTAssertEqual(sink.lines, [], "a record removed on clean exit is not a problem")
    }

    func testKeyFilesAreNeverOpened() throws {
        try writeRecord(status: "busy", updatedAt: 1_790_000_000_000)
        let key = sessionsDir.appendingPathComponent("\(getpid()).0a1b2c3d4e5f6789.key")
        try Data("secret".utf8).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: key.path)
        // Positive control: an unreadable file the source does read is reported.
        let locked = sessionsDir.appendingPathComponent("31337.json")
        try Data("{}".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        let source = makeSource()
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0).map(\.pid), [getpid()])
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(10)).map(\.pid), [getpid()])
        XCTAssertEqual(sink.lines.count, 1, "only the locked record is reported, once: \(sink.lines)")
        XCTAssertTrue(sink.lines.allSatisfy { $0.contains("31337.json") && !$0.contains(".key") }, "\(sink.lines)")
    }

    func testStaleRecordsAreNotSessions() throws {
        try writeRecord(pid: try F.deadPid(), status: "busy", updatedAt: 1_790_000_000_000)
        try writeRecord(pid: getpid(), sessionId: "0b0b0b0b-dead-beef-0000-000000000000", status: "busy",
                        updatedAt: 1_790_000_000_000, procStart: "Mon Jan  1 00:00:00 2001")
        let source = makeSource()
        XCTAssertEqual(source.poll(now: Date()), [], "a crashed session's leftover and a reused pid")
        XCTAssertEqual(sink.lines, [])
    }

    func testHalfWrittenRecordKeepsTheLastGoodState() throws {
        let url = try writeRecord(status: "busy", updatedAt: 1_790_000_000_000)
        let source = makeSource()
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0).map(\.state), [.running])

        try Data(#"{"pid":\#(getpid()),"sessionId":"3f2c1b7a-11"#.utf8).write(to: url)
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(1)).map(\.state), [.running],
                       "a record caught mid-write keeps the session as it was")
        XCTAssertEqual(sink.lines, [], "a write in progress is not worth a log line")
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(7)).map(\.state), [.running])
        XCTAssertEqual(sink.lines.count, 1, "still broken after 5 s: reported")
        _ = source.poll(now: t0.addingTimeInterval(8))
        XCTAssertEqual(sink.lines.count, 1, "and reported once")

        try writeRecord(status: "idle", updatedAt: 1_790_000_060_000)
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(9)).map(\.state), [.idle])

        // A brand-new record caught mid-write is simply not there yet.
        let fresh = sessionsDir.appendingPathComponent("\(getppid()).json")
        try Data(#"{"pid":\#(getppid()),"sess"#.utf8).write(to: fresh)
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(10)).map(\.key.id), [session])
    }

    func testMissingConfigDirIsReportedOnce() {
        let source = makeSource(configDirs: [root.appendingPathComponent("nope")])
        for second in 0..<5 {
            XCTAssertEqual(source.poll(now: Date().addingTimeInterval(TimeInterval(second))), [])
        }
        XCTAssertEqual(sink.lines.count, 1, "\(sink.lines)")
    }

    func testUnreadableTranscriptIsReportedOnce() throws {
        try appendTranscript([F.aiTitle("Private", session: session)])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: transcriptURL.path)
        try writeRecord(status: "busy", updatedAt: 1_790_000_000_000)
        let source = makeSource()
        let t0 = Date()
        let first = source.poll(now: t0)
        XCTAssertEqual(first.map(\.title), ["demo-e1"], "falls back to the registry name")
        try writeRecord(status: "idle", updatedAt: 1_790_000_060_000)
        _ = source.poll(now: t0.addingTimeInterval(6))
        _ = source.poll(now: t0.addingTimeInterval(12))
        XCTAssertEqual(sink.lines.count, 1, "\(sink.lines)")
    }

    func testAutomationIsObservedButNotInteractive() throws {
        try writeRecord(status: "busy", updatedAt: 1_790_000_000_000, entrypoint: "sdk-cli", name: nil)
        let observation = try XCTUnwrap(makeSource().poll(now: Date()).first)
        XCTAssertFalse(observation.interactive)
        XCTAssertEqual(observation.host, .unknown)
        XCTAssertEqual(observation.title, "Claude 3f2c1b7a", "no transcript, no name: the short id")
        XCTAssertNil(observation.lastMessage)
    }

    // MARK: Caching and refresh policy, with a fake process table

    /// A process table the test controls, counting what the source asks it.
    private final class FakeProcessTable {
        var alive: Set<Int32>
        var startMatches: (ClaudeRegistryRecord) -> Bool = { _ in true }
        var aliveChecks = 0
        var startChecks = 0
        var hostLookups = 0

        init(alive: Set<Int32>) {
            self.alive = alive
        }

        /// Holds the table strongly, so it lives as long as the source.
        var probe: ClaudeProcessProbe {
            ClaudeProcessProbe(
                isAlive: { self.aliveChecks += 1; return self.alive.contains($0) },
                startMatches: { self.startChecks += 1; return self.startMatches($0) },
                host: { _ in self.hostLookups += 1; return .unknown })
        }
    }

    func testStartTimeIsCheckedOncePerProcessButAlivenessEveryPoll() throws {
        let table = FakeProcessTable(alive: [4242])
        table.startMatches = { $0.procStart != "stale" }
        let source = makeSource(probe: table.probe)
        try writeRecord(pid: 4242, status: "busy", updatedAt: 1_000, procStart: "Thu Oct  1 02:59:07 2026")
        let t0 = Date()
        for second in 0..<3 {
            XCTAssertEqual(source.poll(now: t0.addingTimeInterval(TimeInterval(second))).count, 1)
        }
        XCTAssertEqual(table.aliveChecks, 3, "kill(pid, 0) on every poll")
        XCTAssertEqual(table.startChecks, 1, "the start-time check once per process")
        XCTAssertEqual(table.hostLookups, 1)

        // Another process behind the same pid is checked afresh; a mismatch sticks without re-checking.
        try writeRecord(pid: 4242, status: "busy", updatedAt: 2_000, procStart: "stale")
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(3)), [])
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(4)), [])
        XCTAssertEqual(table.startChecks, 2)
        XCTAssertEqual(table.aliveChecks, 5)
    }

    func testAVerdictDiesWithItsProcess() throws {
        let table = FakeProcessTable(alive: [4242])
        let source = makeSource(probe: table.probe)
        try writeRecord(pid: 4242, status: "busy", updatedAt: 1_000, procStart: "Thu Oct  1 02:59:07 2026")
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0).count, 1)

        // The session crashes and leaves its record behind.
        table.alive = []
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(1)), [])

        // Later an unrelated process is given the same pid.
        table.alive = [4242]
        table.startMatches = { _ in false }
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(2)), [],
                       "the leftover record must not come back to life with its old verdict")
        XCTAssertEqual(table.startChecks, 2, "the new process behind the pid was checked")
    }

    func testSameSessionInTwoRecordsKeepsTheMostRecentlyUpdated() throws {
        let source = makeSource(probe: FakeProcessTable(alive: [101, 202]).probe)
        try writeRecord(pid: 101, status: "busy", updatedAt: 2_000)
        try writeRecord(pid: 202, status: "idle", updatedAt: 1_000)
        let first = source.poll(now: Date())
        XCTAssertEqual(first.map(\.pid), [101])
        XCTAssertEqual(first.map(\.state), [.running])

        try writeRecord(pid: 202, status: "waiting", updatedAt: 3_000)
        let second = source.poll(now: Date())
        XCTAssertEqual(second.map(\.pid), [202])
        XCTAssertEqual(second.map(\.state), [.waiting])
    }

    func testTranscriptIsReReadOnAStatusChangeOrEveryFiveSeconds() throws {
        let source = makeSource(probe: FakeProcessTable(alive: [777]).probe)
        try appendTranscript([F.assistant(["one"], session: session)])
        try writeRecord(pid: 777, status: "busy", updatedAt: 1_000)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(source.poll(now: t0).first?.lastMessage, "one")

        try appendTranscript([F.assistant(["two"], session: session)])
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(1)).first?.lastMessage, "one", "throttled")
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(4.9)).first?.lastMessage, "one", "throttled")
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(5)).first?.lastMessage, "two", "5 s later")

        try appendTranscript([F.assistant(["three"], session: session)])
        try writeRecord(pid: 777, status: "idle", updatedAt: 2_000)
        XCTAssertEqual(source.poll(now: t0.addingTimeInterval(5.5)).first?.lastMessage, "three",
                       "a status change reads at once")
    }

    func testTitlePrecedence() {
        let record = ClaudeRegistryRecord(pid: 1, sessionId: "9eb4895f-b5d9-41d0-8161-864ac0eecf46", name: "coreos-e1")
        let full = TranscriptInfo(customTitle: "AI Track", aiTitle: "Generated", lastPrompt: "a prompt")
        XCTAssertEqual(ClaudeSource.title(record: record, transcript: full), "AI Track")
        XCTAssertEqual(ClaudeSource.title(record: record, transcript: TranscriptInfo(customTitle: " ", aiTitle: "Generated")),
                       "Generated")
        XCTAssertEqual(ClaudeSource.title(record: record, transcript: TranscriptInfo(lastPrompt: "a prompt")), "coreos-e1")
        var unnamed = record
        unnamed.name = nil
        XCTAssertEqual(ClaudeSource.title(record: unnamed, transcript: TranscriptInfo(lastPrompt: "fix the\n  login   bug")),
                       "fix the login bug")
        XCTAssertEqual(ClaudeSource.title(record: unnamed, transcript: TranscriptInfo()), "Claude 9eb4895f")
    }
}
