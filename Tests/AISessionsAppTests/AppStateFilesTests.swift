import AISessionsCore
import Darwin
import XCTest
@testable import AISessions

/// The app's own files (pause flag, config watch, snapshot) and how the
/// engine picks its sources. Everything lives in a fresh temp directory.
final class AppStateFilesTests: XCTestCase {
    private var root: URL!

    override class func setUp() {
        super.setUp()
        // Log.shared writes under AppPaths.home: keep it off the real ~/.ai-sessions.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ai-sessions-app-tests-home")
        setenv("AI_SESSIONS_HOME", home.path, 1)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sessions-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Pause flag

    func testThePauseFlagIsAFile() throws {
        let flag = PauseFlag(url: root.appendingPathComponent("state/notifications-paused"))
        XCTAssertFalse(flag.isPaused)

        try flag.set(true)
        XCTAssertTrue(flag.isPaused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flag.url.path))

        try flag.set(false)
        XCTAssertFalse(flag.isPaused)
        XCTAssertNoThrow(try flag.set(false), "resuming twice is fine")
    }

    // MARK: Config watch

    func testTheWatcherReportsEachChangeOnce() throws {
        let url = root.appendingPathComponent("config.json")
        var watcher = ConfigWatcher(url: url)
        XCTAssertFalse(watcher.checkForChange(), "still missing")

        try Data(#"{"sound": false}"#.utf8).write(to: url)
        XCTAssertTrue(watcher.checkForChange(), "created")
        XCTAssertFalse(watcher.checkForChange(), "reported once")

        try Data(#"{"sound": true}"#.utf8).write(to: url)
        XCTAssertTrue(watcher.checkForChange(), "rewritten")

        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        XCTAssertTrue(watcher.checkForChange(), "same size, other mtime")

        // Same size, same mtime: only the inode tells this file from the last one.
        let replacement = root.appendingPathComponent("config.json.tmp")
        try Data(#"{"sound": true}"#.utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: replacement.path)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
        XCTAssertTrue(watcher.checkForChange(), "replaced by an atomic save: a new inode")

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(watcher.checkForChange(), "deleted")
        XCTAssertFalse(watcher.checkForChange())
    }

    // MARK: Snapshot

    private func readSnapshot(_ url: URL) throws -> [TrackedSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SnapshotWriter.Snapshot.self, from: Data(contentsOf: url)).sessions
    }

    func testWithoutDelayAChangedListIsWrittenAtOnceAndAnUnchangedOneNot() throws {
        let url = root.appendingPathComponent("state/snapshot.json")
        let writer = SnapshotWriter(url: url, delay: 0)
        let queue = DispatchQueue(label: "test")
        let one = [AppFixtures.session("a", .running)]

        queue.sync { writer.submit(one, on: queue) }
        XCTAssertEqual(try readSnapshot(url).map(\.key), one.map(\.key))

        try FileManager.default.removeItem(at: url)
        queue.sync { writer.submit(one, on: queue) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an unchanged list is not rewritten")

        let two = one + [AppFixtures.session("b", .waiting, unread: true)]
        queue.sync { writer.submit(two, on: queue) }
        XCTAssertEqual(try readSnapshot(url).map(\.key), two.map(\.key))
        XCTAssertEqual(try readSnapshot(url).last?.unread, true)
    }

    func testWithADelayOnlyTheLatestListIsWrittenOnceTheDelayIsOver() throws {
        let url = root.appendingPathComponent("snapshot.json")
        let writer = SnapshotWriter(url: url, delay: 0.3)
        let queue = DispatchQueue(label: "test")
        let first = [AppFixtures.session("a", .running)]
        let latest = [AppFixtures.session("a", .idle, unread: true)]

        queue.sync {
            writer.submit(first, on: queue)
            writer.submit(latest, on: queue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing before the delay")

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { usleep(20_000) }
        queue.sync {} // the write finished
        XCTAssertEqual(try readSnapshot(url), latest)
    }

    func testAFailedWriteIsRetriedEvenWhenTheListDidNotChange() throws {
        let blocker = root.appendingPathComponent("state")
        try Data().write(to: blocker) // a file where the directory should be
        let url = blocker.appendingPathComponent("snapshot.json")
        let writer = SnapshotWriter(url: url, delay: 0)
        let queue = DispatchQueue(label: "test")
        let sessions = [AppFixtures.session("a", .running)]

        queue.sync { writer.submit(sessions, on: queue) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the first write cannot succeed")

        try FileManager.default.removeItem(at: blocker)
        queue.sync { writer.submit(sessions, on: queue) }
        XCTAssertEqual(try readSnapshot(url), sessions)
    }

    func testFlushWritesWhatIsPending() throws {
        let url = root.appendingPathComponent("snapshot.json")
        let writer = SnapshotWriter(url: url, delay: 3600)
        let queue = DispatchQueue(label: "test")
        let sessions = [AppFixtures.session("a", .waiting)]

        queue.sync {
            writer.submit(sessions, on: queue)
            writer.flush()
        }
        XCTAssertEqual(try readSnapshot(url), sessions)
    }

    // MARK: Sources

    func testSourcesFollowTheConfiguredDirectories() {
        var config = Config()
        config.claudeConfigDirs = [root.appendingPathComponent("claude").path]
        config.codexHomes = [root.appendingPathComponent("codex").path]
        XCTAssertEqual(SessionEngine.makeSources(for: config).map(\.agent), [.claude, .codex])

        config.codexHomes = []
        XCTAssertEqual(SessionEngine.makeSources(for: config).map(\.agent), [.claude])

        config.claudeConfigDirs = []
        XCTAssertTrue(SessionEngine.makeSources(for: config).isEmpty)
    }
}
