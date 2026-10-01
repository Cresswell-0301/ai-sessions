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
            lastPrompt: "second prompt", lastAssistantText: "Newest answer",
            lastTurnEnd: TranscriptTurnEnd(.completed)))
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
            aiTitle: "Deep title", lastPrompt: "latest", lastAssistantText: "latest answer",
            lastTurnEnd: TranscriptTurnEnd(.completed), restingTurnEnd: TranscriptTurnEnd(.completed)),
            "nothing was said after the answer, so the conversation rests on it")
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
        XCTAssertEqual(cache.info, TranscriptInfo(lastAssistantText: "hello", lastTurnEnd: TranscriptTurnEnd(.completed),
                                                  restingTurnEnd: TranscriptTurnEnd(.completed)))
        XCTAssertEqual(cache.titleScanCount, 1, "no title in the tail: one backward scan")

        try append(F.filler(totalBytes: 300_000, session: session), to: url)
        try cache.refresh()
        XCTAssertEqual(cache.titleScanCount, 1, "the scan found nothing; it is not repeated for this file")
        XCTAssertEqual(cache.info.lastAssistantText, "hello", "kept after scrolling out of the tail")
        XCTAssertEqual(cache.info.lastTurnEnd, TranscriptTurnEnd(.completed), "so is how the last turn ended")

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

    // MARK: Turn ends

    /// An assistant entry as Claude writes it, with an explicit stop reason
    /// (null while a turn goes on) and timestamp.
    private func answer(_ text: String, stop: String?, at time: String? = nil,
                        sidechain: Bool = false) -> [String: Any] {
        var entry = F.assistant([text], session: session, sidechain: sidechain)
        var message = entry["message"] as! [String: Any]
        message["stop_reason"] = stop ?? NSNull()
        entry["message"] = message
        entry["timestamp"] = time
        return entry
    }

    private func user(_ content: Any, at time: String? = nil, sidechain: Bool = false) -> [String: Any] {
        var entry: [String: Any] = ["type": "user", "sessionId": session, "isSidechain": sidechain,
                                    "message": ["role": "user", "content": content] as [String: Any]]
        entry["timestamp"] = time
        return entry
    }

    private func date(_ text: String) -> Date { CodexLine.date(text)! }

    func testTheNewestTurnEndIsTheLaterOfAnEndTurnAnswerAndAnInterruptMarker() throws {
        let interruptedThenAnswered = try write(F.lines([
            user("[Request interrupted by user]", at: "2026-10-01T03:00:00.000Z"),
            user("try again", at: "2026-10-01T03:01:00.000Z"),
            answer("Done.", stop: "end_turn", at: "2026-10-01T03:02:00.250Z"),
            user("thanks"),
        ]), name: "answered.jsonl")
        XCTAssertEqual(try ClaudeTranscript.readTail(of: interruptedThenAnswered).lastTurnEnd,
                       TranscriptTurnEnd(.completed, at: date("2026-10-01T03:02:00.250Z")))

        let answeredThenInterrupted = try write(F.lines([
            answer("Earlier answer.", stop: "end_turn", at: "2026-10-01T03:00:00.000Z"),
            user("run the migration", at: "2026-10-01T03:01:00.000Z"),
            answer("Running it.", stop: "tool_use", at: "2026-10-01T03:01:05.000Z"),
            user([["type": "tool_result", "tool_use_id": "toolu_1", "is_error": true,
                   "content": "The user doesn't want to proceed with this tool use."]],
                 at: "2026-10-01T03:01:09.000Z"),
            user([["type": "text", "text": "[Request interrupted by user for tool use]"]], at: "2026-10-01T03:01:09.000Z"),
        ]), name: "interrupted.jsonl")
        XCTAssertEqual(try ClaudeTranscript.readTail(of: answeredThenInterrupted).lastTurnEnd,
                       TranscriptTurnEnd(.interrupted, at: date("2026-10-01T03:01:09.000Z")))
    }

    func testOnlyRealTurnEndsCount() throws {
        let url = try write(F.lines([
            answer("The real end.", stop: "end_turn", at: "2026-10-01T03:00:00.000Z"),
            // None of these ends the session's turn:
            answer("Mid-turn, about to call a tool.", stop: "tool_use", at: "2026-10-01T03:01:00.000Z"),
            answer("Streamed before its stop reason.", stop: nil, at: "2026-10-01T03:01:01.000Z"),
            answer("A sub-agent finished.", stop: "end_turn", at: "2026-10-01T03:01:02.000Z", sidechain: true),
            user("[Request interrupted by user]", at: "2026-10-01T03:01:03.000Z", sidechain: true),
            user([["type": "tool_result", "tool_use_id": "toolu_1",
                   "content": "[Request interrupted by user] quoted in a file the agent read"]],
                 at: "2026-10-01T03:01:04.000Z"),
            user("why did you print [Request interrupted by user]?", at: "2026-10-01T03:01:05.000Z"),
        ]))
        XCTAssertEqual(try ClaudeTranscript.readTail(of: url).lastTurnEnd,
                       TranscriptTurnEnd(.completed, at: date("2026-10-01T03:00:00.000Z")))
    }

    func testATurnEndWithoutATimestampIsStillATurnEnd() throws {
        let url = try write(F.lines([user("[Request interrupted by user]")]))
        XCTAssertEqual(try ClaudeTranscript.readTail(of: url).lastTurnEnd, TranscriptTurnEnd(.interrupted))
        let none = try write(F.lines([user("hello"), answer("Thinking out loud.", stop: nil)]), name: "none.jsonl")
        XCTAssertNil(try ClaudeTranscript.readTail(of: none).lastTurnEnd)
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
