import XCTest
@testable import AISessionsCore

final class ModelTests: XCTestCase {
    func testSessionKeyRoundTrip() {
        let key = SessionKey(agent: .claude, id: "9eb4895f-b5d9-41d0-8161-864ac0eecf46")
        XCTAssertEqual(SessionKey(string: key.description), key)
        XCTAssertNil(SessionKey(string: "nope"))
        XCTAssertNil(SessionKey(string: "claude:"))
    }

    func testProcStartParsesAsctimeUTC() {
        let d = ProcessKit.parseProcStart("Thu Oct  1 02:59:07 2026")
        XCTAssertNotNil(d)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 10, 1, 2, 59, 7])
    }

    func testOwnProcessMatchesItsStartTime() {
        let pid = getpid()
        XCTAssertTrue(ProcessKit.isAlive(pid))
        let info = ProcessKit.info(pid)
        XCTAssertNotNil(info)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        XCTAssertTrue(ProcessKit.matchesProcStart(pid, procStart: f.string(from: info!.startTime)))
        XCTAssertFalse(ProcessKit.matchesProcStart(pid, procStart: "Mon Jan  1 00:00:00 2001"))
    }

    func testFormatting() {
        XCTAssertEqual(Formatting.duration(8), "8s")
        XCTAssertEqual(Formatting.duration(4 * 60 + 2), "4m")
        XCTAssertEqual(Formatting.duration(65 * 60), "1h 05m")
        XCTAssertEqual(Formatting.project(for: "/Users/nexflo/coreOS"), "coreOS")
        XCTAssertEqual(Formatting.project(for: "/Users/nexflo/coreOS/.claude/worktrees/inventory"), "coreOS/inventory")
        XCTAssertEqual(Formatting.oneLine("a\n  b   c", max: 80), "a b c")
        XCTAssertEqual(Formatting.oneLine("abcdefghij", max: 5), "abcd…")
    }

    /// [19] Titles and previews come from transcripts and model output; an
    /// ESC or BEL in them would drive the terminal `--route`/`--headless` print to.
    func testOneLineDropsControlCharacters() {
        XCTAssertEqual(Formatting.oneLine("fix bug \u{1B}]0;PWNED\u{07}\u{1B}[31mred\u{9B}2J\u{7F}", max: 200),
                       "fix bug ]0;PWNED[31mred2J")
        XCTAssertEqual(Formatting.oneLine("a\tb\r\nc\u{0}d\u{85}e", max: 80), "a b cd e",
                       "control characters that are whitespace still separate words")
        XCTAssertNil(Formatting.oneLine("\u{1B}\u{07}", max: 80), "nothing printable is left")
    }

    /// Points AppPaths (and so every `Log`) at a fresh home for `body`.
    private func withScratchHome(_ body: (URL) throws -> Void) throws {
        let saved = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ai-sessions-model-\(UUID().uuidString)")
        setenv("AI_SESSIONS_HOME", home.path, 1)
        defer {
            if let saved { setenv("AI_SESSIONS_HOME", saved, 1) } else { unsetenv("AI_SESSIONS_HOME") }
            try? FileManager.default.removeItem(at: home)
        }
        try body(home)
    }

    /// [19] One entry, one line of text: a title's escape must not reach the
    /// `--headless` echo, and a newline in a message must not forge an entry.
    func testALogEntryIsOneLineWithoutControlCharacters() throws {
        try withScratchHome { home in
            let log = Log()
            log.info("claude:1 needs input: \u{1B}]0;PWNED\u{07}deploy\n2026-10-01 00:00:00.000 INFO forged")
            log.flush()
            let text = try String(contentsOf: home.appendingPathComponent("state/ai-sessions.log"), encoding: .utf8)
            XCTAssertEqual(text.split(separator: "\n").count, 1, text.debugDescription)
            XCTAssertFalse(text.unicodeScalars.contains { $0 != "\n" && $0.properties.generalCategory == .control },
                           text.debugDescription)
        }
    }

    /// [9] The app and a command-line run append to one log. Each must add
    /// at the end as it is then, not where it saw the end a moment ago.
    func testTwoWritersOnOneLogKeepEveryLine() throws {
        try withScratchHome { home in
            let writers = [Log(), Log()] // two processes' loggers: own queue, own file handle
            let perWriter = 4000
            DispatchQueue.concurrentPerform(iterations: writers.count) { index in
                for line in 0..<perWriter {
                    writers[index].info("writer\(index) line \(line) claude:5e551011 finished after 4m: AI Track [coreOS]")
                }
                writers[index].flush()
            }
            let text = try String(contentsOf: home.appendingPathComponent("state/ai-sessions.log"), encoding: .utf8)
            let whole = text.split(separator: "\n").filter { $0.contains(" INFO writer") && $0.hasSuffix("[coreOS]") }
            XCTAssertEqual(whole.count, writers.count * perWriter, "lines lost or garbled by the other writer")
        }
    }

    func testConfigDefaultsAndPartialJSON() throws {
        let partial = #"{"minTurnSecondsToNotify": 30, "unknownKey": 1}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: partial)
        XCTAssertEqual(c.minTurnSecondsToNotify, 30)
        XCTAssertEqual(c.claudeConfigDirs, ["~/.claude"])
        XCTAssertTrue(c.notificationsEnabled)
    }
}

/// The logger's file handling: rotation, and two writers on one file.
final class LogFileTests: XCTestCase {
    private var home: URL!
    private var saved: String?
    private var logURL: URL { home.appendingPathComponent("state/ai-sessions.log") }

    override func setUpWithError() throws {
        saved = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ai-sessions-log-\(UUID().uuidString)")
        setenv("AI_SESSIONS_HOME", home.path, 1)
    }

    override func tearDown() {
        if let saved { setenv("AI_SESSIONS_HOME", saved, 1) } else { unsetenv("AI_SESSIONS_HOME") }
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func lines(_ url: URL) -> [Substring] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n")
    }

    func testPastOneMegabyteTheLogMovesToDotOneAndANewOneStarts() {
        let log = Log()
        let filler = String(repeating: "x", count: 1000)
        for i in 0..<1100 { log.info("line \(i) \(filler)") }
        log.info("the last line")
        log.flush()

        let rotated = lines(logURL.appendingPathExtension("1"))
        let current = lines(logURL)
        XCTAssertFalse(rotated.isEmpty, "no ai-sessions.log.1")
        XCTAssertTrue(current.last?.hasSuffix("the last line") == true, "\(current.last ?? "")")
        XCTAssertEqual(rotated.count + current.count, 1101, "rotation loses nothing the first time")
    }

    /// Both writers see the full file; one moves it, the other must notice
    /// and not move the fresh file over the history just kept.
    func testTwoWritersRotatingTogetherLoseNoLine() {
        let writers = [Log(), Log()]
        let perWriter = 7000 // about 1.4 MB in all: exactly one rotation
        DispatchQueue.concurrentPerform(iterations: writers.count) { index in
            for line in 0..<perWriter {
                writers[index].info("writer\(index) line \(line) claude:5e551011 finished after 4m: AI Track [coreOS]")
            }
            writers[index].flush()
        }
        let all = lines(logURL.appendingPathExtension("1")) + lines(logURL)
        XCTAssertFalse(lines(logURL.appendingPathExtension("1")).isEmpty, "it rotated")
        XCTAssertEqual(all.filter { $0.hasSuffix("[coreOS]") }.count, writers.count * perWriter)
    }

    func testANewLogIsOwnerOnly() throws {
        let log = Log()
        log.info("hello")
        log.flush()
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logURL.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    func testAFileOverrideTakesTheLines() {
        let log = Log()
        let own = home.appendingPathComponent("state/headless/headless.log")
        log.file = own
        log.info("headless line")
        log.flush()
        XCTAssertEqual(lines(own).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }
}

/// config.json: missing, valid and broken files, and the last good copy.
final class ConfigFileTests: XCTestCase {
    private var home: URL!
    private var savedHome: String?
    private let noEnvironment: [String: String] = [:]

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ai-sessions-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Config warns through Log.shared, which writes under AppPaths.home:
        // without this, a broken-config test logs into the real ~/.ai-sessions.
        savedHome = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"]
        setenv("AI_SESSIONS_HOME", home.path, 1)
    }

    override func tearDown() {
        Log.shared.flush()
        if let savedHome { setenv("AI_SESSIONS_HOME", savedHome, 1) } else { unsetenv("AI_SESSIONS_HOME") }
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: home.appendingPathComponent("config.json"))
    }

    func testReadTellsMissingFromValidFromBroken() throws {
        XCTAssertEqual(Config.read(home: home), .missing)

        try write(#"{"sound": false}"#)
        guard case .valid(let config, let data) = Config.read(home: home) else { return XCTFail("not valid") }
        XCTAssertFalse(config.sound)
        XCTAssertEqual(data, Data(#"{"sound": false}"#.utf8))

        for broken in ["// a note\n{\"sound\": false}", "{\"sound\": false", "", "[1, 2]", "null"] {
            try write(broken)
            guard case .invalid(let reason) = Config.read(home: home) else {
                return XCTFail("\(broken.debugDescription) should be invalid")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        // The parser's own words follow ("Unexpected end of file"; they vary by OS version).
        try write("{\"sound\": false")
        guard case .invalid(let reason) = Config.read(home: home) else { return XCTFail() }
        XCTAssertTrue(reason.hasPrefix("not valid JSON: "), reason)
        try write("[1, 2]")
        XCTAssertEqual(Config.read(home: home), .invalid(reason: "not a JSON object"))
    }

    func testALaunchFallsBackToTheLastGoodCopyThenToTheDefaults() throws {
        try write(#"{"notificationsEnabled": false}"#)
        XCTAssertNil(Config.lastGood(home: home))
        guard case .valid(_, let data) = Config.read(home: home) else { return XCTFail() }
        Config.rememberLastGood(data, home: home)
        XCTAssertEqual(Config.lastGood(home: home)?.notificationsEnabled, false)

        try write(#"{"notificationsEnabled": true,"#) // half-typed
        let launch = Config.launch(home: home, environment: noEnvironment)
        XCTAssertEqual(launch.config.notificationsEnabled, false, "the last good copy stood in")
        XCTAssertTrue(launch.usedLastGood)

        Config.forgetLastGood(home: home)
        let bare = Config.launch(home: home, environment: noEnvironment)
        XCTAssertEqual(bare.config, Config(), "no copy: the defaults")
        XCTAssertFalse(bare.usedLastGood)
    }

    func testEnvironmentOverridesApplyWhateverTheFileHolds() throws {
        let environment = ["AI_SESSIONS_CLAUDE_DIRS": "/a:/b", "AI_SESSIONS_CODEX_HOMES": ""]
        XCTAssertEqual(Config.load(home: home, environment: environment).claudeConfigDirs, ["/a", "/b"])
        try write(#"{"pollIntervalSeconds": 0.01, "codexHomes": ["~/x"]}"#)
        let config = Config.load(home: home, environment: environment)
        XCTAssertEqual(config.codexHomes, [], "overridden")
        XCTAssertEqual(config.pollIntervalSeconds, 0.25, "held to the floor")
    }

    func testTheStateDirectoryIsMadeOwnerOnlyWithoutFollowingLinks() throws {
        let state = home.appendingPathComponent("state")
        let nested = state.appendingPathComponent("headless")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: file)
        let outside = home.appendingPathComponent("outside.txt")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("link"), withDestinationURL: outside)
        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let farFile = elsewhere.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: farFile)
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("linked-dir"), withDestinationURL: elsewhere)
        for (path, mode) in [(state.path, 0o755), (nested.path, 0o755), (file.path, 0o644), (outside.path, 0o644),
                             (elsewhere.path, 0o755), (farFile.path, 0o644)] {
            XCTAssertEqual(chmod(path, mode_t(mode)), 0)
        }

        AppPaths.secureStateDirectory(state, create: false)

        func mode(_ url: URL) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(mode(state), 0o700)
        XCTAssertEqual(mode(nested), 0o700)
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(mode(outside), 0o644, "a link out of state/ is not followed")
        XCTAssertEqual(mode(elsewhere), 0o755, "nor a linked directory")
        XCTAssertEqual(mode(farFile), 0o644, "nor what is in it")

        let fresh = home.appendingPathComponent("fresh-state")
        AppPaths.secureStateDirectory(fresh, create: true)
        XCTAssertEqual(mode(fresh), 0o700)
    }
}
