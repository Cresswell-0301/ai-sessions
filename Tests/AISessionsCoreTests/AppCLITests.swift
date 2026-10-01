import Darwin
import XCTest
@testable import AISessionsCore

/// Runs the built `AISessions` executable against a fixture Claude registry
/// whose one session is this test process (alive, with a matching start
/// time). Covers the command-line modes of main.swift end to end. Nothing
/// here reads or writes the real ~/.claude, ~/.codex or ~/.ai-sessions; the
/// router may read VS Code's log folder, read-only, and no assertion depends
/// on what it finds there.
final class AppCLITests: XCTestCase {
    private let sessionId = "5e551011-c11a-4e57-8000-00000000c11a"
    private var key: String { "claude:\(sessionId)" }
    private var root: URL!
    private var claudeDir: URL { root.appendingPathComponent("claude", isDirectory: true) }
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var stateDir: URL { home.appendingPathComponent("state", isDirectory: true) }
    private var recordURL: URL { claudeDir.appendingPathComponent("sessions/\(getpid()).json") }

    override func setUpWithError() throws {
        root = try ClaudeFixtures.makeTempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: claudeDir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let transcript = claudeDir.appendingPathComponent("projects/-work-demo-app/\(sessionId).jsonl")
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ClaudeFixtures.lines([
            ClaudeFixtures.customTitle("Fixture tab", session: sessionId),
            ClaudeFixtures.assistant(["All done: three files changed."], session: sessionId),
        ]).write(to: transcript)
        try writeRecord(status: "idle", at: Date().addingTimeInterval(-120))
    }

    override func tearDown() {
        ClaudeFixtures.removeTree(root)
        super.tearDown()
    }

    // MARK: - --version and usage

    func testVersionMatchesTheBundleVersion() throws {
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.packageRoot.appendingPathComponent("Resources/Info.plist")),
            format: nil) as? [String: Any]
        let version = try XCTUnwrap(plist?["CFBundleShortVersionString"] as? String)

        let run = try execute(["--version"])

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "AI Sessions \(version)\n")
    }

    func testBadArgumentsExitWithUsageError() throws {
        for arguments in [["--bogus"], ["--open"], ["--route"], ["--headless", "--version"]] {
            let run = try execute(arguments)
            XCTAssertEqual(run.status, 64, "\(arguments)")
            XCTAssertTrue(run.stderr.contains("usage: AISessions"), "\(arguments): \(run.stderr)")
            XCTAssertEqual(run.stdout, "", "\(arguments)")
        }
    }

    // MARK: - --route

    func testRoutePrintsTheDeepLinkToTheSession() throws {
        let run = try execute(["--route", key])

        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stdout.contains("session   \(key)\n"), run.stdout)
        XCTAssertTrue(run.stdout.contains("title     Fixture tab\n"), run.stdout)
        let url = try routeURL(in: run.stdout)
        XCTAssertEqual(url.scheme, "vscode")
        XCTAssertEqual(url.host, "anthropic.claude-code")
        XCTAssertEqual(url.path, "/open")
        XCTAssertEqual(url.queryItems?.first { $0.name == "session" }?.value, sessionId)
        XCTAssertFalse(run.stdout.contains("result "), "without --open nothing is executed")
    }

    func testRouteLeavesTheAppStateAlone() throws {
        let run = try execute(["--route", key])

        XCTAssertEqual(run.status, 0, run.stderr)
        // It ticks a tracker, which saves its store: that must be a scratch one.
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("state.json").path))
    }

    func testRouteAcceptsAUniquePrefixOfTheId() throws {
        let run = try execute(["--route", String(sessionId.prefix(8))])

        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stdout.contains("session   \(key)\n"), run.stdout)
    }

    func testRouteReachesACodexThreadThroughTheCodexHomes() throws {
        let threadId = "01a0c2d8-e5d4-7b12-aef3-21e7666556fc"
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let day = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayDirectory = codexHome.appendingPathComponent(
            String(format: "sessions/%04d/%02d/%02d", day.year!, day.month!, day.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        try Data((CodexFixture.meta(id: threadId, cwd: "/work/codex-app")
                  + CodexFixture.taskStarted("2026-10-01T03:00:01.000Z")
                  + CodexFixture.taskComplete("2026-10-01T03:00:09.000Z", message: "Rebased; specs green.")).utf8)
            .write(to: dayDirectory.appendingPathComponent("rollout-2026-10-01T11-00-00-\(threadId).jsonl"))
        var environment = self.environment
        environment["AI_SESSIONS_CODEX_HOMES"] = codexHome.path

        let run = try execute(["--route", "codex:\(threadId)"], environment: environment)

        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stdout.contains("session   codex:\(threadId)\n"), run.stdout)
        let url = try routeURL(in: run.stdout)
        XCTAssertEqual(url.scheme, "vscode")
        XCTAssertEqual(url.host, "openai.chatgpt")
        XCTAssertEqual(url.path, "/local/\(threadId)")
    }

    func testRouteToAnUnknownSessionFailsAndListsTheLiveOnes() throws {
        let run = try execute(["--route", "claude:00000000-dead"])

        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(run.stderr.contains("no live session matches \"claude:00000000-dead\""), run.stderr)
        XCTAssertTrue(run.stderr.contains("\(key)  Fixture tab"), run.stderr)
        XCTAssertEqual(run.stdout, "")
    }

    // MARK: - --headless

    func testHeadlessSnapshotsAnnouncesAndStopsOnSIGTERM() throws {
        let run = try Background(Self.executable(), ["--headless"], environment: environment, in: root)
        defer { run.kill() }

        let first = try waitForSnapshot { $0.first?.state == .idle }
        XCTAssertEqual(first.map(\.key.description), [key])
        XCTAssertEqual(first.first?.title, "Fixture tab")
        XCTAssertEqual(first.first?.lastMessage, "All done: three files changed.")

        try writeRecord(status: "waiting", at: Date())
        let waiting = try waitForSnapshot { $0.first?.state == .waiting }
        XCTAssertEqual(waiting.first?.unread, true, "a new question is unread")
        try waitUntil("the needs-input event is logged") { run.stderr.contains("\(key) needs input: Fixture tab") }

        run.signal(SIGTERM)
        let status = try run.wait()
        XCTAssertEqual(status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("headless: stopped by SIGTERM"), run.stderr)
        XCTAssertTrue(run.stdout.contains("1 session\n"), run.stdout)
        XCTAssertTrue(run.stdout.contains("waiting  \(key)  Fixture tab — demo-app · Claude"), run.stdout)
        let state = try String(contentsOf: stateDir.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertTrue(state.contains(key), "the tracker state is saved under AI_SESSIONS_HOME")
    }

    func testHeadlessStopsCleanlyOnSIGINT() throws {
        let run = try Background(Self.executable(), ["--headless"], environment: environment, in: root)
        defer { run.kill() }
        _ = try waitForSnapshot { !$0.isEmpty }

        run.signal(SIGINT)

        XCTAssertEqual(try run.wait(), 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("headless: stopped by SIGINT"), run.stderr)
    }

    // MARK: - Fixtures

    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["AI_SESSIONS_HOME"] = home.path
        environment["AI_SESSIONS_CLAUDE_DIRS"] = claudeDir.path
        environment["AI_SESSIONS_CODEX_HOMES"] = "" // no Codex homes at all
        return environment
    }

    private func writeRecord(status: String, at date: Date) throws {
        try ClaudeFixtures.recordData(pid: getpid(), sessionId: sessionId, status: status,
                                      updatedAt: (date.timeIntervalSince1970 * 1000).rounded(),
                                      procStart: ClaudeFixtures.ownProcStart).write(to: recordURL, options: .atomic)
    }

    /// The `url` line of a `--route` plan.
    private func routeURL(in stdout: String) throws -> URLComponents {
        let line = try XCTUnwrap(stdout.split(separator: "\n").first { $0.hasPrefix("url ") }, stdout)
        return try XCTUnwrap(URLComponents(string: line.dropFirst(4).trimmingCharacters(in: .whitespaces)))
    }

    private func waitForSnapshot(timeout: TimeInterval = 15,
                                 until condition: ([TrackedSession]) -> Bool) throws -> [TrackedSession] {
        let url = stateDir.appendingPathComponent("snapshot.json")
        var sessions: [TrackedSession] = []
        try waitUntil("snapshot.json satisfies the condition", timeout: timeout) {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? Self.decoder.decode(Snapshot.self, from: data) else { return false }
            sessions = snapshot.sessions
            return condition(sessions)
        }
        return sessions
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure("timed out waiting until \(what)") }
            usleep(50_000)
        }
    }

    private func execute(_ arguments: [String],
                         environment: [String: String]? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let run = try Background(Self.executable(), arguments, environment: environment ?? self.environment, in: root)
        defer { run.kill() }
        let status = try run.wait()
        return (status, run.stdout, run.stderr)
    }

    private struct Snapshot: Decodable {
        var sessions: [TrackedSession]
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The executable `swift test` builds next to this test bundle (it builds
    /// every target, so this is the current code).
    private static func executable() throws -> URL {
        let url = Bundle(for: AppCLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AISessions")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Failure("no AISessions executable at \(url.path); run `swift build` first")
        }
        return url
    }

    /// A child process whose output goes to files, so a chatty child can
    /// never block on a full pipe.
    private final class Background {
        let process = Process()
        private let outURL: URL
        private let errURL: URL

        init(_ executable: URL, _ arguments: [String], environment: [String: String], in directory: URL) throws {
            let id = UUID().uuidString
            outURL = directory.appendingPathComponent("\(id).out")
            errURL = directory.appendingPathComponent("\(id).err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = try FileHandle(forWritingTo: outURL)
            process.standardError = try FileHandle(forWritingTo: errURL)
            try process.run()
        }

        var stdout: String { (try? String(contentsOf: outURL, encoding: .utf8)) ?? "" }
        var stderr: String { (try? String(contentsOf: errURL, encoding: .utf8)) ?? "" }

        func signal(_ number: Int32) { Darwin.kill(process.processIdentifier, number) }

        /// The exit status; a death by signal is reported as 128 + signal.
        func wait(timeout: TimeInterval = 20) throws -> Int32 {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                guard Date() < deadline else { throw Failure("AISessions \(process.arguments ?? []) did not exit") }
                usleep(20_000)
            }
            return process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
        }

        func kill() {
            if process.isRunning { process.terminate() }
        }
    }
}
