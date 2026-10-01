import SQLite3
import XCTest
@testable import AISessionsCore

final class CodexSourceTests: XCTestCase {
    private typealias F = CodexFixture
    private var tmp: URL!
    private var home: URL { tmp.appendingPathComponent("codex", isDirectory: true) }

    private let idA = "01a0c2d8-e5d4-7b12-aef3-21e7666556fc"
    private let idB = "01a0c73f-5340-7702-9375-d02c43d3c18f"
    private let idC = "01a0c894-49df-7102-92b1-6cf77abbf88e"
    private let idD = "01a09ee1-98e3-7441-853e-c982175b4e79"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions", isDirectory: true),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: Fixtures

    private func makeSource(recentHours: Double = 12, homes: [URL]? = nil) -> CodexSource {
        let source = CodexSource(homes: homes ?? [home], recentHours: recentHours)
        source.logger = { _ in }
        return source
    }

    private func dayDirectory(_ day: Date, in home: URL) -> URL {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        func pad(_ n: Int?, _ width: Int) -> String {
            let digits = String(n ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return home.appendingPathComponent("sessions/\(pad(parts.year, 4))/\(pad(parts.month, 2))/\(pad(parts.day, 2))",
                                           isDirectory: true)
    }

    @discardableResult
    private func writeRollout(_ id: String, _ text: String, day: Date = Date(), modified: Date? = nil,
                              home: URL? = nil) throws -> URL {
        let directory = dayDirectory(day, in: home ?? self.home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-10-01T11-00-00-\(id).jsonl")
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func completed(_ id: String, prompt: String = "check the build", answer: String = "Done.",
                           originator: String = "codex_vscode", source: String = CodexFixture.vscodeSource) -> String {
        F.meta(id: id, originator: originator, source: source)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.userMessage("2026-10-01T03:00:01.100Z", prompt)
            + F.agentMessage("2026-10-01T03:00:04.000Z", "Looking.")
            + F.taskComplete("2026-10-01T03:00:09.000Z", message: answer)
    }

    private func running(_ id: String, prompt: String = "keep going") -> String {
        F.meta(id: id) + F.taskStarted("2026-10-01T03:00:01.000Z") + F.userMessage("2026-10-01T03:00:01.100Z", prompt)
    }

    private func titles(_ observations: [Observation]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: observations.map { ($0.key.id, $0.title ?? "") })
    }

    // MARK: Observations

    func testReportsAThreadFromTodaysDirectory() throws {
        let prompt = "pull the latest changes from the feature branch, rebase it onto staging and then run every affected spec"
        try writeRollout(idA, F.meta(id: idA, cwd: "/Users/me/coreOS")
                         + F.taskStarted("2026-10-01T03:00:01.000Z")
                         + F.userMessage("2026-10-01T03:00:01.100Z", prompt)
                         + F.taskComplete("2026-10-01T03:00:09.000Z", message: "Rebased; 12 specs green."))
        let observations = makeSource().poll(now: Date())

        XCTAssertEqual(observations.count, 1)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.key, SessionKey(agent: .codex, id: idA))
        XCTAssertEqual(observation.key.description, "codex:\(idA)")
        XCTAssertEqual(observation.state, .idle)
        XCTAssertEqual(observation.rawStatus, "task_complete")
        XCTAssertEqual(observation.stateSince, F.date("2026-10-01T03:00:09.000Z"))
        XCTAssertEqual(observation.cwd, "/Users/me/coreOS")
        XCTAssertEqual(observation.entrypoint, "codex_vscode")
        XCTAssertEqual(observation.host, .vscode(extensionHostPid: nil))
        XCTAssertNil(observation.pid)
        XCTAssertTrue(observation.interactive)
        XCTAssertEqual(observation.lastMessage, "Rebased; 12 specs green.")
        // No DB and no index: the first prompt, on one line, at most 80 characters.
        let title = try XCTUnwrap(observation.title)
        XCTAssertTrue(title.hasPrefix("pull the latest changes from the feature branch"), title)
        XCTAssertEqual(title.count, 80)
        XCTAssertEqual(title.last, "…")
    }

    func testAutomationAndTerminalThreads() throws {
        try writeRollout(idA, completed(idA, source: CodexFixture.subagentSource))
        try writeRollout(idB, completed(idB, originator: "codex_exec", source: #""exec""#))
        try writeRollout(idC, completed(idC, originator: "codex_cli_rs", source: #""cli""#))
        try writeRollout(idD, completed(idD, source: CodexFixture.guardianSource))
        let byId = Dictionary(uniqueKeysWithValues: makeSource().poll(now: Date()).map { ($0.key.id, $0) })

        XCTAssertEqual(byId.count, 4)
        XCTAssertEqual(byId[idA]?.interactive, false)
        XCTAssertEqual(byId[idB]?.interactive, false)
        XCTAssertEqual(byId[idB]?.host, .unknown)
        XCTAssertEqual(byId[idC]?.interactive, true)
        XCTAssertEqual(byId[idC]?.host, .terminal(appPid: nil))
        XCTAssertEqual(byId[idC]?.entrypoint, "codex_cli_rs")
        XCTAssertEqual(byId[idD]?.interactive, false)
    }

    func testAppendedTurnEndFlipsRunningToIdleBetweenPolls() throws {
        let url = try writeRollout(idA, running(idA))
        let source = makeSource()
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0).first?.state, .running)
        XCTAssertEqual(source.poll(now: t0 + 1).first?.stateSince, F.date("2026-10-01T03:00:01.000Z"))

        try append(F.agentMessage("2026-10-01T03:04:00.000Z", "Almost.") + F.taskComplete("2026-10-01T03:04:30.000Z", message: nil), to: url)
        let observation = try XCTUnwrap(source.poll(now: t0 + 2).first)
        XCTAssertEqual(observation.state, .idle)
        XCTAssertEqual(observation.stateSince, F.date("2026-10-01T03:04:30.000Z"))
        XCTAssertEqual(observation.lastMessage, "Almost.")
    }

    func testNewRolloutsAppearOnTheNextRescan() throws {
        let source = makeSource()
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0), [])
        try writeRollout(idA, running(idA))
        XCTAssertEqual(source.poll(now: t0 + 5), [], "directories are rescanned every 10 s, not every poll")
        XCTAssertEqual(source.poll(now: t0 + 10).map(\.key.id), [idA])
    }

    func testRecencyWindowAndRunningThreads() throws {
        let now = Date()
        try writeRollout(idA, completed(idA), modified: now - 13 * 3600)
        try writeRollout(idB, completed(idB))
        try writeRollout(idC, running(idC))
        let source = makeSource(recentHours: 12)

        XCTAssertEqual(source.poll(now: now).map(\.key.id), [idB, idC], "a rollout quiet for 13 h is not picked up")
        let later = now + 13 * 3600
        XCTAssertEqual(source.poll(now: later).map(\.key.id), [idC], "idle and quiet: dropped; running: kept")
        XCTAssertEqual(source.poll(now: later + 10).map(\.key.id), [idC], "a dropped thread is not rediscovered")
    }

    func testDeletedRolloutEndsTheThread() throws {
        let url = try writeRollout(idA, completed(idA))
        let source = makeSource()
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0).count, 1)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(source.poll(now: t0 + 1), [])
    }

    func testBrokenRolloutsDoNotBreakPolling() throws {
        try writeRollout(idA, "this is not a rollout\n" + F.taskStarted("2026-10-01T03:00:01.000Z"))
        try writeRollout(idB, "")
        try writeRollout(idC, F.meta(id: idC) + "{\"half\n" + "[1,2]\n" + F.taskStarted("2026-10-01T03:00:01.000Z"))
        let source = makeSource()
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0).map(\.key.id), [idC])
        XCTAssertEqual(source.poll(now: t0).first?.state, .running)

        // The empty file gets its meta line later.
        let empty = dayDirectory(Date(), in: home).appendingPathComponent("rollout-2026-10-01T11-00-00-\(idB).jsonl")
        try append(running(idB), to: empty)
        XCTAssertEqual(source.poll(now: t0 + 1).map(\.key.id), [idB, idC])
        XCTAssertEqual(source.trackedRolloutCount, 3)

        // Once quiet, the unreadable one is let go; the running ones stay.
        XCTAssertEqual(source.poll(now: t0 + 13 * 3600).map(\.key.id), [idB, idC])
        XCTAssertEqual(source.trackedRolloutCount, 2)
    }

    func testOneObservationPerThreadAcrossHomes() throws {
        let second = tmp.appendingPathComponent("codex-2", isDirectory: true)
        try writeRollout(idA, completed(idA), modified: Date() - 60)
        try writeRollout(idA, running(idA), home: second)
        let observations = makeSource(homes: [home, second]).poll(now: Date())
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.state, .running, "the rollout written last wins")
    }

    // MARK: Discovery

    func testYesterdaysDirectoryIsScannedEvenForAShortWindow() throws {
        let now = Date()
        try writeRollout(idA, running(idA), day: now - 86_400)
        XCTAssertEqual(makeSource(recentHours: 1).poll(now: now).map(\.key.id), [idA])
    }

    func testResumedThreadInAnOldDirectoryIsFoundThroughTheStateDB() throws {
        let now = Date()
        let resumed = try writeRollout(idA, running(idA), day: now - 5 * 86_400)
        XCTAssertEqual(makeSource().poll(now: now), [], "the day directories alone miss it")

        let archived = try writeRollout(idB, running(idB), day: now - 6 * 86_400)
        let elsewhere = tmp.appendingPathComponent("rollout-2026-09-01T00-00-00-\(idC).jsonl")
        try Data(running(idC).utf8).write(to: elsewhere)
        let db = try StateDatabaseFixture(path: home.appendingPathComponent("state_5.sqlite").path)
        try db.put(id: idA, rolloutPath: resumed.path, updatedAt: now, title: "Resumed thread")
        try db.put(id: idB, rolloutPath: archived.path, updatedAt: now, title: "Archived", archived: true)
        try db.put(id: idC, rolloutPath: elsewhere.path, updatedAt: now, title: "Outside sessions/")
        db.close()

        let observations = makeSource().poll(now: now)
        XCTAssertEqual(observations.map(\.key.id), [idA])
        XCTAssertEqual(observations.first?.title, "Resumed thread")
    }

    func testDayDirectories() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = F.date("2026-10-01T10:00:00.000Z")
        XCTAssertEqual(CodexSource.dayDirectories(sessionsRoot: "/s", now: now, cutoff: now - 12 * 3600, calendar: calendar),
                       ["/s/2026/09/30", "/s/2026/10/01"])
        XCTAssertEqual(CodexSource.dayDirectories(sessionsRoot: "/s", now: now, cutoff: now - 72 * 3600, calendar: calendar),
                       ["/s/2026/09/28", "/s/2026/09/29", "/s/2026/09/30", "/s/2026/10/01"])
        let capped = CodexSource.dayDirectories(sessionsRoot: "/s", now: now, cutoff: now - 10_000 * 3600, calendar: calendar)
        XCTAssertEqual(capped.count, CodexSource.maxScanDays)
        XCTAssertEqual(capped.last, "/s/2026/10/01")
    }

    // MARK: Titles

    func testTitlesFromTheStateDB() throws {
        let ideOnly = "# Context from my IDE setup:\n\n## Open tabs:\n- Inve"
        for id in [idA, idB, idC, idD] { try writeRollout(id, completed(id, prompt: "prompt of \(id.prefix(8))")) }
        let path = home.appendingPathComponent("state_5.sqlite").path
        let db = try StateDatabaseFixture(path: path)
        try db.put(id: idA, title: ideOnly, name: "R176")
        try db.put(id: idB, title: "Audit finance inventory procurement", name: nil)
        try db.put(id: idC, title: ideOnly, name: "")
        db.close()
        // Read-only: the source can open it without write access and leaves it untouched.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let byId = titles(makeSource().poll(now: Date()))
        XCTAssertEqual(byId[idA], "R176", "the thread's name beats a title that is the raw prompt")
        XCTAssertEqual(byId[idB], "Audit finance inventory procurement")
        XCTAssertEqual(byId[idC], "prompt of 01a0c894", "a title that is only IDE context is skipped")
        XCTAssertEqual(byId[idD], "prompt of 01a09ee1", "no row: the first prompt")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-journal"))
    }

    func testMissingTitleIsRequeriedAtMostEvery30Seconds() throws {
        try writeRollout(idA, completed(idA, prompt: "fallback prompt"))
        let db = try StateDatabaseFixture(path: home.appendingPathComponent("state_5.sqlite").path)
        let source = makeSource()
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0).first?.title, "fallback prompt")

        try db.put(id: idA, title: "Named later")
        XCTAssertEqual(source.poll(now: t0 + 10).first?.title, "fallback prompt")
        XCTAssertEqual(source.poll(now: t0 + 29).first?.title, "fallback prompt")
        XCTAssertEqual(source.poll(now: t0 + 30).first?.title, "Named later")

        // A found title is kept for a while, then re-read.
        try db.put(id: idA, title: "Renamed")
        XCTAssertEqual(source.poll(now: t0 + 60).first?.title, "Named later")
        XCTAssertEqual(source.poll(now: t0 + 150).first?.title, "Renamed")
        db.close()
    }

    func testRenameInTheSessionIndexRefreshesTheTitleAtOnce() throws {
        try writeRollout(idA, completed(idA))
        let db = try StateDatabaseFixture(path: home.appendingPathComponent("state_5.sqlite").path)
        try db.put(id: idA, title: "Check meeting minutes", name: "R168")
        let index = home.appendingPathComponent("session_index.jsonl")
        try Data((#"{"id":"\#(idA)","thread_name":"R168","updated_at":"2026-08-13T09:17:15.607647Z"}"# + "\n").utf8).write(to: index)
        let source = makeSource()
        let t0 = Date()
        XCTAssertEqual(source.poll(now: t0).first?.title, "R168")

        try db.put(id: idA, title: "Check meeting minutes", name: "R169")
        try append(#"{"id":"\#(idA)","thread_name":"R169","updated_at":"2026-10-01T09:17:15.607647Z"}"# + "\n", to: index)
        XCTAssertEqual(source.poll(now: t0 + 10).first?.title, "R169")
        db.close()
    }

    func testSessionIndexWithoutAStateDB() throws {
        try writeRollout(idA, completed(idA))
        try writeRollout(idB, completed(idB, prompt: "no name for this one"))
        let lines = [
            #"{"id":"\#(idA)","thread_name":"First name","updated_at":"2026-09-22T10:06:02.283803Z"}"#,
            #"{"id":"\#(idC)","thread_name":"Someone else","updated_at":"2026-09-22T10:06:03.000000Z"}"#,
            "{broken",
            #"{"id":"\#(idA)","thread_name":"Latest name","updated_at":"2026-09-22T11:00:00.000000Z"}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: home.appendingPathComponent("session_index.jsonl"))
        let byId = titles(makeSource().poll(now: Date()))
        XCTAssertEqual(byId[idA], "Latest name")
        XCTAssertEqual(byId[idB], "no name for this one")
    }

    func testNewestStateDBWins() throws {
        try writeRollout(idA, completed(idA))
        for (version, title) in [(9, "Nine"), (10, "Ten")] {
            let db = try StateDatabaseFixture(path: home.appendingPathComponent("state_\(version).sqlite").path)
            try db.put(id: idA, title: title)
            db.close()
        }
        XCTAssertEqual(makeSource().poll(now: Date()).first?.title, "Ten")
    }

    func testOlderSchemaWithoutNameColumn() throws {
        try writeRollout(idA, completed(idA))
        let db = try StateDatabaseFixture(path: home.appendingPathComponent("state_4.sqlite").path, nameColumn: false)
        try db.put(id: idA, title: "Plain title")
        db.close()
        XCTAssertEqual(makeSource().poll(now: Date()).first?.title, "Plain title")
    }

    func testReadsAWALDatabaseWhileCodexHoldsItOpen() throws {
        try writeRollout(idA, completed(idA, prompt: "fallback"))
        let writer = try StateDatabaseFixture(path: home.appendingPathComponent("state_5.sqlite").path, wal: true)
        try writer.put(id: idA, title: "Written through WAL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("state_5.sqlite-wal").path))
        XCTAssertEqual(makeSource().poll(now: Date()).first?.title, "Written through WAL")
        writer.close()
    }

    func testTitlePrecedence() {
        func title(_ name: String?, _ index: String?, _ stored: String?, _ prompt: String?) -> String {
            CodexSource.title(name: name, indexName: index, storedTitle: stored, firstUserMessage: prompt, id: idA)
        }
        XCTAssertEqual(title("R176", "Index", "Stored", "prompt"), "R176")
        XCTAssertEqual(title(" ", "Index", "Stored", "prompt"), "Index")
        XCTAssertEqual(title(nil, nil, "Stored\n  title", "prompt"), "Stored title")
        XCTAssertEqual(title(nil, nil, "# Context from my IDE setup:\n## My request:\nfix it", "prompt"), "fix it")
        XCTAssertEqual(title(nil, nil, "# Context from my IDE setup:\n## Open tabs:", "the prompt"), "the prompt")
        XCTAssertEqual(title(nil, nil, nil, nil), "Codex 01a0c2d8")
    }
}

/// A `state_<N>.sqlite` shaped like Codex's (the columns the source reads).
private final class StateDatabaseFixture {
    private var handle: OpaquePointer?
    private let nameColumn: Bool

    init(path: String, wal: Bool = false, nameColumn: Bool = true) throws {
        self.nameColumn = nameColumn
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw Failure(message: "open \(path)")
        }
        if wal { try exec("PRAGMA journal_mode=WAL") }
        try exec("""
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT 0,
              updated_at INTEGER NOT NULL, source TEXT NOT NULL DEFAULT 'vscode', cwd TEXT NOT NULL DEFAULT '',
              title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0\(nameColumn ? ", name TEXT" : ""))
            """)
        try exec("CREATE INDEX idx_threads_updated_at ON threads(updated_at DESC, id DESC)")
    }

    deinit {
        close()
    }

    func put(id: String, rolloutPath: String = "/nowhere", updatedAt: Date = Date(), title: String,
             name: String? = nil, archived: Bool = false) throws {
        let sql = nameColumn
            ? "INSERT OR REPLACE INTO threads (id, rollout_path, updated_at, title, archived, name) VALUES (?, ?, ?, ?, ?, ?)"
            : "INSERT OR REPLACE INTO threads (id, rollout_path, updated_at, title, archived) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure(message: sql) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, rolloutPath, -1, transient)
        sqlite3_bind_int64(statement, 3, Int64(updatedAt.timeIntervalSince1970))
        sqlite3_bind_text(statement, 4, title, -1, transient)
        sqlite3_bind_int64(statement, 5, archived ? 1 : 0)
        if nameColumn {
            if let name { sqlite3_bind_text(statement, 6, name, -1, transient) } else { sqlite3_bind_null(statement, 6) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(message: "insert \(id)") }
    }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: sql) }
    }

    struct Failure: Error {
        let message: String
    }
}
