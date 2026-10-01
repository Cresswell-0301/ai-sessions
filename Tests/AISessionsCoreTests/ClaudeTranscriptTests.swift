import XCTest
@testable import AISessionsCore

final class ClaudeTranscriptTests: XCTestCase {
    private typealias F = ClaudeFixtures
    private let session = "7d1c0a52-3b4e-4f60-9a71-8b2c3d4e5f60"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try F.makeTempDir()
    }

    override func tearDown() {
        F.removeTree(dir)
    }

    private func write(_ data: Data, name: String = "transcript.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: Reading

    func testNewestEntryOfEachKindWins() throws {
        let url = try write(F.lines([
            F.aiTitle("Old generated title", session: session),
            F.customTitle("Old tab name", session: session),
            F.lastPrompt("first prompt", session: session),
            F.assistant(["Old answer"], session: session),
            F.aiTitle("Session tracking and notifications system", session: session),
            F.customTitle("AI Track", session: session),
            F.lastPrompt("second prompt", session: session),
            F.assistant(["Newest answer"], session: session),
            F.user("thanks", session: session),
        ]))
        XCTAssertEqual(try ClaudeTranscript.readTail(of: url), TranscriptInfo(
            customTitle: "AI Track", aiTitle: "Session tracking and notifications system",
            lastPrompt: "second prompt", lastAssistantText: "Newest answer"))
    }

    func testLastAssistantTextIsTheNewestEntryThatHasText() throws {
        let url = try write(F.lines([
            F.assistant(["An older answer"], session: session),
            F.assistant(["Here is the plan.", "  ", "Second block."], session: session),
            F.toolUse(session: session),
            F.user("tool output", session: session),
            F.assistant(content: [["type": "thinking", "thinking": "hmm", "signature": "sig"]], session: session),
            F.assistant([" \n\t "], session: session),
            F.assistant(["sub-agent chatter"], session: session, sidechain: true),
        ]))
        XCTAssertEqual(try ClaudeTranscript.readTail(of: url).lastAssistantText, "Here is the plan.\nSecond block.",
                       "tool calls, thinking, blank text and sidechain entries are skipped; text blocks are joined")
    }

    func testEntriesWithoutTheirPayloadDoNotSettleAKind() throws {
        let url = try write(F.lines([
            F.customTitle("Renamed once", session: session),
            F.lastPrompt("the real prompt", session: session),
            ["type": "last-prompt", "leafUuid": "abc", "sessionId": session],
            F.customTitle("   ", session: session),
            F.aiTitle("Generated", session: session),
        ]))
        let info = try ClaudeTranscript.readTail(of: url)
        XCTAssertEqual(info.lastPrompt, "the real prompt", "an older-format entry without lastPrompt is skipped")
        XCTAssertNil(info.customTitle, "a blank rename is the newest custom title: cleared")
        XCTAssertEqual(info.aiTitle, "Generated")
    }

    func testTailSkipsTheCutFirstLineAndAnUnfinishedLastLine() throws {
        // [ai-title][custom-title, ~3 KB][filler ... last-prompt][unfinished line]
        // with the 256 KB boundary falling inside the custom-title line.
        let beyond = F.line(F.aiTitle("Beyond the tail", session: session))
        var cut = F.customTitle("Cut in half", session: session)
        cut["padding"] = String(repeating: "p", count: 3_000)
        let cutLine = F.line(cut)
        let prompt = F.line(F.lastPrompt("the prompt", session: session))
        let unfinished = Data(#"{"type":"ai-title","aiTitle":"Unfinish"#.utf8)
        let after = ClaudeTranscript.tailBytes - 1_500
        let filler = F.filler(totalBytes: after - prompt.count - unfinished.count, session: session)
        let url = try write(beyond + cutLine + filler + prompt + unfinished)

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let boundary = size - ClaudeTranscript.tailBytes
        XCTAssertTrue(boundary > beyond.count && boundary < beyond.count + cutLine.count,
                      "precondition: the tail starts inside the custom-title line")

        XCTAssertEqual(try ClaudeTranscript.readTail(of: url), TranscriptInfo(lastPrompt: "the prompt"),
                       "neither the cut first line nor the unfinished last line is read as an entry")
        XCTAssertEqual(try ClaudeTranscript.read(url), TranscriptInfo(
            customTitle: "Cut in half", aiTitle: "Beyond the tail", lastPrompt: "the prompt"),
            "the backward scan reassembles the line the tail cut")
    }

    func testBackwardScanFindsATitleOlderThanTheTail() throws {
        let url = try write(
            F.line(F.aiTitle("Deep title", session: session))
                + F.filler(totalBytes: 1_000_000, session: session)
                + F.lines([F.lastPrompt("latest", session: session), F.assistant(["latest answer"], session: session)]))
        XCTAssertNil(try ClaudeTranscript.readTail(of: url).aiTitle, "precondition: the title is not in the tail")
        XCTAssertEqual(try ClaudeTranscript.read(url), TranscriptInfo(
            aiTitle: "Deep title", lastPrompt: "latest", lastAssistantText: "latest answer"))
    }

    func testBackwardScanStopsAtFourMegabytes() throws {
        let tail = F.line(F.lastPrompt("latest", session: session))
        let reachable = try write(
            F.line(F.aiTitle("Deep enough", session: session))
                + F.filler(totalBytes: ClaudeTranscript.titleScanLimit - 64_000, session: session) + tail,
            name: "reachable.jsonl")
        let unreachable = try write(
            F.line(F.aiTitle("Too deep", session: session))
                + F.filler(totalBytes: ClaudeTranscript.titleScanLimit + 64_000, session: session) + tail,
            name: "unreachable.jsonl")
        XCTAssertEqual(try ClaudeTranscript.read(reachable).aiTitle, "Deep enough")
        XCTAssertEqual(try ClaudeTranscript.read(unreachable), TranscriptInfo(lastPrompt: "latest"))
    }

    func testTitleScanRunsOncePerFileAndKnownValuesSurviveTheTail() throws {
        let configDir = dir.appendingPathComponent("config")
        let projectDir = configDir.appendingPathComponent("projects/-p")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent("\(session).jsonl")
        try (F.filler(totalBytes: 300_000, session: session) + F.line(F.assistant(["hello"], session: session)))
            .write(to: url)

        let cache = ClaudeTranscriptCache(sessionId: session, configDir: configDir, cwd: "/p")
        XCTAssertNotNil(cache.currentStamp(now: Date()))
        try cache.refresh()
        XCTAssertEqual(cache.info, TranscriptInfo(lastAssistantText: "hello"))
        XCTAssertEqual(cache.titleScanCount, 1, "no title in the tail: one backward scan")

        try append(F.filler(totalBytes: 300_000, session: session), to: url)
        try cache.refresh()
        XCTAssertEqual(cache.titleScanCount, 1, "the scan found nothing; it is not repeated for this file")
        XCTAssertEqual(cache.info.lastAssistantText, "hello", "kept after scrolling out of the tail")

        try append(F.line(F.aiTitle("Named later", session: session)), to: url)
        try cache.refresh()
        XCTAssertEqual(cache.info.aiTitle, "Named later")

        try append(F.filler(totalBytes: 300_000, session: session), to: url)
        try cache.refresh()
        XCTAssertEqual(cache.info.aiTitle, "Named later", "kept after scrolling out of the tail")
        XCTAssertEqual(cache.titleScanCount, 1)

        // A replaced file (new inode) starts over.
        try FileManager.default.removeItem(at: url)
        try F.line(F.aiTitle("Fresh", session: session)).write(to: url)
        XCTAssertNotNil(cache.currentStamp(now: Date()))
        try cache.refresh()
        XCTAssertEqual(cache.info, TranscriptInfo(aiTitle: "Fresh"))
    }

    // MARK: Locating

    func testProjectDirectoryNameMatchesClaudesEncoding() {
        XCTAssertEqual(ClaudeTranscript.projectDirectoryName(for: "/Users/nexflo/coreOS"), "-Users-nexflo-coreOS")
        XCTAssertEqual(ClaudeTranscript.projectDirectoryName(for: "/Users/nexflo/coreOS/.claude/worktrees/procurement"),
                       "-Users-nexflo-coreOS--claude-worktrees-procurement")
        XCTAssertEqual(ClaudeTranscript.projectDirectoryName(for: "/Users/me/Café Notes"), "-Users-me-Caf--Notes")
        XCTAssertEqual(ClaudeTranscript.projectDirectoryName(for: "/tmp/x\u{1F600}"), "-tmp-x--",
                       "one dash per UTF-16 unit, as JavaScript counts")
        XCTAssertNil(ClaudeTranscript.projectDirectoryName(for: "/" + String(repeating: "a", count: 200)),
                     "longer names are hashed by Claude: glob instead")
    }

    func testLocateTriesTheEncodedCwdThenGlobs() throws {
        let configDir = dir.appendingPathComponent("config")
        let direct = configDir.appendingPathComponent("projects/-work-app")
        let hashed = configDir.appendingPathComponent("projects/-work-a-very-long-path-1a2b3c")
        for directory in [direct, hashed] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: direct.appendingPathComponent("aaa.jsonl"))
        try Data().write(to: hashed.appendingPathComponent("bbb.jsonl"))

        XCTAssertEqual(ClaudeTranscript.locate(sessionId: "aaa", configDir: configDir, cwd: "/work/app")?.lastPathComponent,
                       "aaa.jsonl")
        XCTAssertEqual(ClaudeTranscript.locate(sessionId: "bbb", configDir: configDir, cwd: "/elsewhere")?
            .deletingLastPathComponent().lastPathComponent, "-work-a-very-long-path-1a2b3c")
        XCTAssertNil(ClaudeTranscript.locate(sessionId: "ccc", configDir: configDir, cwd: "/work/app"))
        XCTAssertNil(ClaudeTranscript.locate(sessionId: "aaa", configDir: dir.appendingPathComponent("nope"), cwd: nil))
    }

    func testMissingTranscriptIsGlobbedAtMostEveryThirtySeconds() throws {
        let configDir = dir.appendingPathComponent("config")
        let hashed = configDir.appendingPathComponent("projects/-hashed-name-9f8e")
        try FileManager.default.createDirectory(at: hashed, withIntermediateDirectories: true)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)

        let globbed = ClaudeTranscriptCache(sessionId: "s-glob", configDir: configDir, cwd: "/not/here")
        XCTAssertNil(globbed.currentStamp(now: t0))
        try Data().write(to: hashed.appendingPathComponent("s-glob.jsonl"))
        XCTAssertNil(globbed.currentStamp(now: t0.addingTimeInterval(10)), "no second glob within 30 s")
        XCTAssertNil(globbed.currentStamp(now: t0.addingTimeInterval(29)))
        XCTAssertNotNil(globbed.currentStamp(now: t0.addingTimeInterval(30)))

        // The encoded-cwd guess is a single stat, tried on every poll.
        let direct = ClaudeTranscriptCache(sessionId: "s-direct", configDir: configDir, cwd: "/direct/path")
        XCTAssertNil(direct.currentStamp(now: t0))
        let directDir = configDir.appendingPathComponent("projects/-direct-path")
        try FileManager.default.createDirectory(at: directDir, withIntermediateDirectories: true)
        try Data().write(to: directDir.appendingPathComponent("s-direct.jsonl"))
        XCTAssertNotNil(direct.currentStamp(now: t0.addingTimeInterval(1)))
    }
}
