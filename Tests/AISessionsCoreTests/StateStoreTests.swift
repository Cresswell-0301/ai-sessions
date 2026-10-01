import Darwin
import XCTest
@testable import AISessionsCore

final class StateStoreTests: XCTestCase {
    private static let scratchHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-sessions-tests-home", isDirectory: true)
    private static var savedHome: String?

    /// Log.shared and `standard()` resolve under AppPaths.home: keep both off
    /// the real ~/.ai-sessions.
    override class func setUp() {
        super.setUp()
        savedHome = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        setenv("AI_SESSIONS_HOME", scratchHome.path, 1)
    }

    override class func tearDown() {
        Log.shared.flush()
        if let savedHome { setenv("AI_SESSIONS_HOME", savedHome, 1) } else { unsetenv("AI_SESSIONS_HOME") }
        super.tearDown()
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_800_000)
    private var root: URL!
    private var url: URL { root.appendingPathComponent("nested/state/state.json") }
    private let claudeA = SessionKey(agent: .claude, id: "9eb4895f-b5d9-41d0-8161-864ac0eecf46")
    private let codexB = SessionKey(agent: .codex, id: "0199a1b2-7c3d-7e4f")
    private let claudeC = SessionKey(agent: .claude, id: "c")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func record(_ state: ActivityState, seen: Date, unread: Bool = false,
                        ended: Bool = false) -> StateStore.Record {
        StateStore.Record(state: state, stateSince: seen, turnStartedAt: nil, unread: unread,
                          ended: ended, lastSeen: seen)
    }

    private func writeRaw(_ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func inode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }

    func testAMissingFileIsAFirstRunWithNoRecordsAndLoadingWritesNothing() {
        let store = StateStore(url: url)
        XCTAssertTrue(store.isFirstRun)
        XCTAssertFalse(store.initialized)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testSaveCreatesDirectoriesAndRoundTripsEveryFieldExactly() throws {
        let store = StateStore(url: url)
        let saved = StateStore.Record(
            state: .running, stateSince: Date(timeIntervalSince1970: 1_790_823_673.8216789),
            turnStartedAt: Date(timeIntervalSince1970: 1_790_823_600.123), lastTurnDuration: 12.5,
            unread: true, ended: false, lastSeen: t0, pid: 48433, procStart: "Thu Oct  1 02:59:07 2026",
            lastTurnEnd: .interrupted)
        store.update(saved, for: codexB)
        store.update(record(.idle, seen: t0, ended: true), for: claudeA)
        store.markInitialized()
        try store.save(now: t0)

        let loaded = StateStore(url: url)
        XCTAssertFalse(loaded.isFirstRun)
        XCTAssertEqual(loaded.record(for: codexB), saved, "dates come back to the last bit")
        XCTAssertEqual(loaded.record(for: claudeA), record(.idle, seen: t0, ended: true))
        XCTAssertEqual(loaded.records.count, 2)
    }

    func testSaveRenamesANewFileIntoPlaceAndLeavesNoTempFiles() throws {
        let store = StateStore(url: url)
        store.update(record(.idle, seen: t0), for: claudeA)
        try store.save(now: t0)
        let firstInode = try inode(url)
        store.update(record(.running, seen: t0), for: codexB)
        try store.save(now: t0)
        XCTAssertNotEqual(try inode(url), firstInode, "replaced by rename, never rewritten in place")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["state.json"])
        XCTAssertEqual(StateStore(url: url).records.count, 2)
    }

    func testACorruptFileReadsAsAFirstRunAndIsKeptAside() throws {
        let truncated = #"{"version": 1, "initialized": true, "sessions": {"claude:c": {"state": "idle", "unr"#
        try writeRaw(truncated)
        let store = StateStore(url: url)
        XCTAssertTrue(store.isFirstRun, "corrupt is treated as not initialized: silent adoption")
        XCTAssertTrue(store.records.isEmpty)
        let aside = url.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), truncated, "kept for inspection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        store.markInitialized()
        try store.save(now: t0)
        XCTAssertFalse(StateStore(url: url).isFirstRun, "the next save starts a clean file")
    }

    func testARecordWrittenBeforeTheProcessWasRememberedStillLoads() throws {
        try writeRaw("""
        {"version": 1, "initialized": true, "sessions": {
          "claude:c": {"state": "running", "stateSince": 1790800000, "turnStartedAt": 1790800000,
                       "unread": false, "ended": false, "lastSeen": 1790800000}
        }}
        """)
        let record = try XCTUnwrap(StateStore(url: url).record(for: claudeC))
        XCTAssertEqual(record.state, .running)
        XCTAssertNil(record.pid)
        XCTAssertNil(record.procStart)
        XCTAssertNil(record.lastTurnEnd)
    }

    func testOtherUnusableContentAlsoReadsAsAFirstRun() throws {
        for text in ["", "[]", "null", #"{"initialized": "yes"}"#, #"{"initialized": true, "sessions": []}"#] {
            try writeRaw(text)
            let store = StateStore(url: url)
            XCTAssertTrue(store.isFirstRun, "for \(text.debugDescription)")
            XCTAssertTrue(store.records.isEmpty, "for \(text.debugDescription)")
        }
    }

    func testAnUnreadableRecordIsSkippedAndTheRestKept() throws {
        try writeRaw("""
        {"version": 1, "initialized": true, "sessions": {
          "claude:c": {"state": "idle", "unread": true, "ended": false, "lastSeen": 1790800000},
          "claude:future": {"state": "paused", "unread": false, "ended": false, "lastSeen": 1790800000},
          "not-a-key": {"state": "idle", "unread": false, "ended": false, "lastSeen": 1790800000}
        }}
        """)
        let store = StateStore(url: url)
        XCTAssertFalse(store.isFirstRun)
        XCTAssertEqual(Array(store.records.keys), [claudeC])
        XCTAssertEqual(store.record(for: claudeC)?.unread, true)
    }

    func testSaveDropsRecordsNotSeenForADay() throws {
        let store = StateStore(url: url)
        let now = t0.addingTimeInterval(StateStore.retention + 100)
        store.update(record(.idle, seen: now.addingTimeInterval(-StateStore.retention - 1)), for: claudeA)
        store.update(record(.idle, seen: now.addingTimeInterval(-StateStore.retention)), for: codexB)
        store.update(record(.running, seen: now.addingTimeInterval(-60)), for: claudeC)
        try store.save(now: now)
        XCTAssertEqual(Set(store.records.keys), [codexB, claudeC], "exactly a day old is still kept")
        XCTAssertEqual(Set(StateStore(url: url).records.keys), [codexB, claudeC])
    }

    func testChangesAreWrittenAtOnceButLastSeenAloneOnlyEveryFewMinutes() {
        let store = StateStore(url: url)
        store.update(record(.idle, seen: t0), for: claudeA)
        store.saveIfNeeded(now: t0)
        XCTAssertEqual(StateStore(url: url).record(for: claudeA)?.lastSeen, t0)

        var later = record(.idle, seen: t0)
        later.lastSeen = t0 + 1
        store.update(later, for: claudeA)
        store.saveIfNeeded(now: t0 + 1)
        XCTAssertEqual(StateStore(url: url).record(for: claudeA)?.lastSeen, t0, "lastSeen alone waits")

        later.unread = true
        later.lastSeen = t0 + 2
        store.update(later, for: claudeA)
        store.saveIfNeeded(now: t0 + 2)
        XCTAssertEqual(StateStore(url: url).record(for: claudeA)?.unread, true, "a real change is written at once")

        let due = t0 + 2 + StateStore.lastSeenWriteInterval
        later.lastSeen = due
        store.update(later, for: claudeA)
        store.saveIfNeeded(now: due)
        XCTAssertEqual(StateStore(url: url).record(for: claudeA)?.lastSeen, due)
    }

    func testClosingAndClearingUnread() throws {
        let store = StateStore(url: url)
        store.update(record(.idle, seen: t0, unread: true), for: claudeA)
        store.update(record(.running, seen: t0), for: codexB)
        store.update(record(.waiting, seen: t0, unread: true), for: claudeC)
        store.closeAll(except: [codexB])
        XCTAssertEqual(store.record(for: claudeA)?.ended, true)
        XCTAssertEqual(store.record(for: claudeC)?.ended, true)
        XCTAssertEqual(store.record(for: codexB)?.ended, false)
        store.close(codexB)
        XCTAssertEqual(store.record(for: codexB)?.ended, true)

        store.clearUnread(claudeA)
        XCTAssertEqual(store.record(for: claudeA)?.unread, false)
        XCTAssertEqual(store.record(for: claudeC)?.unread, true)
        store.clearAllUnread()
        XCTAssertFalse(store.records.values.contains(where: \.unread))
        try store.save(now: t0)
        XCTAssertEqual(StateStore(url: url).records, store.records)
    }

    func testAFailedSaveThrowsAndTheChangeIsWrittenOnceItCan() throws {
        // The state directory's parent is a regular file, so nothing can be created.
        let blocker = root.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let target = blocker.appendingPathComponent("state/state.json")
        let store = StateStore(url: target)
        store.update(record(.idle, seen: t0, unread: true), for: claudeA)
        XCTAssertThrowsError(try store.save(now: t0))
        store.saveIfNeeded(now: t0) // logged, not fatal
        try FileManager.default.removeItem(at: blocker)
        store.saveIfNeeded(now: t0 + 1)
        XCTAssertEqual(StateStore(url: target).record(for: claudeA)?.unread, true)
    }

    func testTheStandardStoreLivesInTheStateDirectory() {
        // Loading reads (and could move aside) the file: only ever under the scratch home.
        guard AppPaths.home.path == AppPaths.expand(Self.scratchHome.path).path else {
            return XCTFail("AI_SESSIONS_HOME is not isolated; not touching \(AppPaths.home.path)")
        }
        XCTAssertEqual(StateStore.standard().url.path, AppPaths.stateDir.appendingPathComponent("state.json").path)
    }
}
