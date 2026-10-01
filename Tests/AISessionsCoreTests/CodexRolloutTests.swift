import XCTest
@testable import AISessionsCore

/// Rollout lines in the layout Codex writes (`timestamp`, `ordinal`, `type`,
/// `payload`, payload `type` first), shaped after real 0.146–0.155 rollouts.
enum CodexFixture {
    static let vscodeSource = #""vscode""#
    static let subagentSource = #"{"subagent":{"thread_spawn":{"parent_thread_id":"01a0c894-49df-7102-92b1-6cf77abbf88e","depth":1,"agent_path":"/root/audit"}}}"#
    static let guardianSource = #"{"subagent":{"other":"guardian"}}"#

    static func json(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    static func date(_ text: String) -> Date {
        CodexLine.date(text)!
    }

    /// `padding` grows the embedded base instructions; real meta lines are ~20 KB.
    static func meta(id: String, cwd: String = "/Users/me/project", originator: String = "codex_vscode",
                     source: String = vscodeSource, threadSource: String = "user",
                     time: String = "2026-10-01T03:00:00.000Z", padding: Int = 0) -> String {
        let instructions = String(repeating: "x", count: padding)
        return #"{"timestamp":"\#(time)","ordinal":0,"type":"session_meta","payload":{"session_id":"\#(id)","id":"\#(id)","timestamp":"\#(time)","cwd":\#(json(cwd)),"originator":"\#(originator)","cli_version":"0.155.0-alpha","source":\#(source),"thread_source":"\#(threadSource)","model_provider":"openai","base_instructions":{"text":"\#(instructions)"}}}"# + "\n"
    }

    static func event(_ type: String, _ time: String, _ fields: String = "") -> String {
        let extra = fields.isEmpty ? "" : "," + fields
        return #"{"timestamp":"\#(time)","ordinal":1,"type":"event_msg","payload":{"type":"\#(type)"\#(extra)}}"# + "\n"
    }

    static func taskStarted(_ time: String) -> String {
        event("task_started", time, #""turn_id":"t1","started_at":1790000000,"model_context_window":258400,"collaboration_mode_kind":"default""#)
    }

    static func taskComplete(_ time: String, message: String?) -> String {
        event("task_complete", time, #""turn_id":"t1","last_agent_message":\#(message.map(json) ?? "null"),"started_at":1790000000,"completed_at":1790000100,"duration_ms":100000"#)
    }

    static func turnAborted(_ time: String) -> String {
        event("turn_aborted", time, #""turn_id":"t1","reason":"interrupted","duration_ms":4000"#)
    }

    static func agentMessage(_ time: String, _ text: String, phase: String = "commentary") -> String {
        event("agent_message", time, #""message":\#(json(text)),"phase":"\#(phase)","memory_citation":null"#)
    }

    static func userMessage(_ time: String, _ text: String) -> String {
        event("user_message", time, #""client_id":"c1","message":\#(json(text)),"images":[],"local_images":[]"#)
    }

    /// The form builds before 0.154.0-alpha.6.2 use for both sides of the conversation.
    static func itemCompleted(_ time: String, item: String, text: String) -> String {
        let blockType = item == "AgentMessage" ? "Text" : "text"
        return event("item_completed", time, #""thread_id":"th","turn_id":"t1","item":{"type":"\#(item)","id":"i1","content":[{"type":"\#(blockType)","text":\#(json(text))}],"phase":"final_answer"},"started_at_ms":1,"completed_at_ms":2"#)
    }

    static func tokenCount(_ time: String) -> String {
        event("token_count", time, #""info":{"total_token_usage":{"input_tokens":1}}"#)
    }

    static func approvalRequest(_ time: String) -> String {
        event("exec_approval_request", time, #""call_id":"call_1","command":["git","push"],"cwd":"/Users/me/project""#)
    }

    /// A tool-output line; `size` pads it (real ones reach 4.6 MB).
    static func responseItem(_ time: String, type: String = "custom_tool_call_output", size: Int = 0) -> String {
        let filler = String(repeating: "y", count: size)
        return #"{"timestamp":"\#(time)","ordinal":2,"type":"response_item","payload":{"type":"\#(type)","call_id":"call_1","output":"\#(filler)"}}"# + "\n"
    }

    /// About `bytes` of tool output in `lineSize`-byte lines, stamped `time`.
    static func filler(_ time: String, bytes: Int, lineSize: Int = 16 * 1024) -> String {
        let line = responseItem(time, size: lineSize)
        return String(repeating: line, count: max(1, bytes / line.utf8.count))
    }
}

final class CodexRolloutTests: XCTestCase {
    private typealias F = CodexFixture
    private var tmp: URL!
    private let id = "01a0c2d8-e5d4-7b12-aef3-21e7666556fc"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRolloutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func rollout(_ text: String, name: String = "rollout.jsonl") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        try append(Data(text.utf8), to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func size(of url: URL) throws -> Int64 {
        Int64(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int))
    }

    // MARK: Meta

    func testMetaFromEachKindOfThread() throws {
        let vscode = try XCTUnwrap(CodexSessionMeta(line: Data(F.meta(id: id, cwd: "/Users/me/coreOS").utf8)))
        XCTAssertEqual(vscode, CodexSessionMeta(id: id, cwd: "/Users/me/coreOS", originator: "codex_vscode",
                                                sourceKind: "vscode", threadSource: "user", cliVersion: "0.155.0-alpha"))
        XCTAssertTrue(vscode.isInteractive)
        XCTAssertEqual(vscode.host, .vscode(extensionHostPid: nil))

        let subagent = try XCTUnwrap(CodexSessionMeta(line: Data(F.meta(id: "a1", source: F.subagentSource, threadSource: "subagent").utf8)))
        XCTAssertEqual(subagent.sourceKind, "subagent")
        XCTAssertFalse(subagent.isInteractive)

        let guardian = try XCTUnwrap(CodexSessionMeta(line: Data(F.meta(id: "g1", source: F.guardianSource, threadSource: "guardian_review").utf8)))
        XCTAssertEqual(guardian.sourceKind, "subagent")
        XCTAssertFalse(guardian.isInteractive)

        let exec = try XCTUnwrap(CodexSessionMeta(line: Data(F.meta(id: "e1", originator: "codex_exec", source: #""exec""#).utf8)))
        XCTAssertEqual(exec.sourceKind, "exec")
        XCTAssertFalse(exec.isInteractive)
        XCTAssertEqual(exec.host, .unknown)
        // An exec originator is automation whatever its source says.
        XCTAssertFalse(CodexSessionMeta(id: "e2", originator: "codex_exec", sourceKind: "vscode").isInteractive)

        let cli = try XCTUnwrap(CodexSessionMeta(line: Data(F.meta(id: "c1", originator: "codex_cli_rs", source: #""cli""#).utf8)))
        XCTAssertTrue(cli.isInteractive)
        XCTAssertEqual(cli.host, .terminal(appPid: nil))

        XCTAssertEqual(CodexSessionMeta.sourceKind(of: ["mcp": [:]]), "mcp")
        XCTAssertEqual(CodexSessionMeta.sourceKind(of: ["a": 1, "b": 2]), "other")
        XCTAssertEqual(CodexSessionMeta.sourceKind(of: nil), "unknown")
        XCTAssertEqual(CodexSessionMeta.sourceKind(of: 3), "unknown")
    }

    func testMetaRejectsOtherLines() {
        XCTAssertNil(CodexSessionMeta(line: Data(F.taskStarted("2026-10-01T03:00:01.000Z").utf8)))
        XCTAssertNil(CodexSessionMeta(line: Data(#"{"type":"session_meta","payload":{"cwd":"/x"}}"#.utf8)))
        XCTAssertNil(CodexSessionMeta(line: Data(#"{"type":"session_meta","payload":"#.utf8)))
        XCTAssertNil(CodexSessionMeta(line: Data([0xFF, 0xFE, 0x7B])))
    }

    // MARK: Turns

    func testCompletedTurnFromEventMessages() throws {
        let url = try rollout(
            F.meta(id: id)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.userMessage("2026-10-01T03:00:01.100Z", "pull the latest changes\n")
            + F.agentMessage("2026-10-01T03:00:05.000Z", "Checking the branch first.")
            + F.responseItem("2026-10-01T03:00:06.000Z")
            + F.agentMessage("2026-10-01T03:00:09.000Z", "Pulled 3 commits.", phase: "final_answer")
            + F.tokenCount("2026-10-01T03:00:09.100Z")
            + F.taskComplete("2026-10-01T03:00:09.316Z", message: "Pulled 3 commits; the tree is clean."))
        let reader = CodexRolloutReader(url: url)
        XCTAssertEqual(reader.update(), .changed)

        XCTAssertEqual(reader.meta?.id, id)
        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:00:09.316Z"))
        XCTAssertEqual(reader.rawStatus, "task_complete")
        XCTAssertEqual(reader.turnEnd, .completed)
        XCTAssertEqual(reader.lastMessage, "Pulled 3 commits; the tree is clean.")
        XCTAssertEqual(reader.firstUserMessage, "pull the latest changes")
        XCTAssertEqual(reader.offset, try size(of: url))
        XCTAssertEqual(reader.update(), .unchanged)
    }

    func testOlderBuildsCompletedItemsAndAnEmptyFinalMessage() throws {
        let url = try rollout(
            F.meta(id: id)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.itemCompleted("2026-10-01T03:00:01.200Z", item: "UserMessage", text: "read this n build it")
            + F.itemCompleted("2026-10-01T03:00:04.000Z", item: "AgentMessage", text: "Mapping the workspace.")
            + F.itemCompleted("2026-10-01T03:00:08.000Z", item: "AgentMessage", text: "Built it.")
            + F.event("item_completed", "2026-10-01T03:00:08.500Z", #""item":{"type":"CommandExecution","stdout":"lots"}"#)
            + F.taskComplete("2026-10-01T03:00:09.000Z", message: nil))
        let reader = CodexRolloutReader(url: url)
        reader.update()

        XCTAssertEqual(reader.state, .idle)
        // A null last_agent_message (53 of 648 real turns) leaves the latest agent message.
        XCTAssertEqual(reader.lastMessage, "Built it.")
        XCTAssertEqual(reader.firstUserMessage, "read this n build it")
    }

    func testAbortedTurnIsIdle() throws {
        let url = try rollout(
            F.meta(id: id)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.agentMessage("2026-10-01T03:00:02.000Z", "Starting.")
            + F.turnAborted("2026-10-01T03:00:05.500Z"))
        let reader = CodexRolloutReader(url: url)
        reader.update()

        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.rawStatus, "turn_aborted")
        XCTAssertEqual(reader.turnEnd, .interrupted, "Stop: the turn did not finish its answer")
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:00:05.500Z"))
        XCTAssertEqual(reader.lastMessage, "Starting.")

        try append(F.taskStarted("2026-10-01T03:01:00.000Z"), to: url)
        reader.update()
        XCTAssertNil(reader.turnEnd, "a new turn has not ended")
        try append(F.approvalRequest("2026-10-01T03:01:05.000Z"), to: url)
        reader.update()
        XCTAssertNil(reader.turnEnd)
        try append(F.responseItem("2026-10-01T03:01:30.000Z", type: "function_call_output")
                   + F.taskComplete("2026-10-01T03:02:00.000Z", message: "Done."), to: url)
        reader.update()
        XCTAssertEqual(reader.turnEnd, .completed)
    }

    func testThreadWithoutTurnsIsIdleSinceCreationThenCapturesFirstPrompt() throws {
        let url = try rollout(F.meta(id: id, time: "2026-10-01T02:59:59.000Z"))
        let reader = CodexRolloutReader(url: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T02:59:59.000Z"))
        XCTAssertNil(reader.rawStatus)
        XCTAssertNil(reader.turnEnd, "no turn has ended")
        XCTAssertNil(reader.firstUserMessage)

        try append(F.taskStarted("2026-10-01T03:00:01.000Z")
                   + F.userMessage("2026-10-01T03:00:01.100Z", "first")
                   + F.userMessage("2026-10-01T03:05:00.000Z", "second"), to: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.state, .running)
        XCTAssertEqual(reader.firstUserMessage, "first")
    }

    func testIDEContextIsStrippedFromTheFirstPrompt() throws {
        let prompt = "# Context from my IDE setup:\n\n## Open tabs:\n- a.ts: web/a.ts\n\n## My request:\nfix the totals\n## Error Type\nRuntime"
        let url = try rollout(F.meta(id: id) + F.userMessage("2026-10-01T03:00:01.000Z", prompt))
        let reader = CodexRolloutReader(url: url)
        reader.update()
        XCTAssertEqual(reader.firstUserMessage, "fix the totals\n## Error Type\nRuntime")
    }

    // MARK: Incremental reads

    func testAppendedLinesFlipRunningToIdle() throws {
        let url = try rollout(
            F.meta(id: id)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.agentMessage("2026-10-01T03:00:02.000Z", "Running the tests."))
        let reader = CodexRolloutReader(url: url)
        reader.update()
        XCTAssertEqual(reader.state, .running)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:00:01.000Z"))
        XCTAssertEqual(reader.lastMessage, "Running the tests.")

        // Tool output and token counts change nothing a user sees.
        try append(F.responseItem("2026-10-01T03:00:03.000Z", size: 5000) + F.tokenCount("2026-10-01T03:00:03.100Z"), to: url)
        XCTAssertEqual(reader.update(), .unchanged)
        XCTAssertEqual(reader.offset, try size(of: url))

        let before = reader.bytesRead
        try append(F.taskComplete("2026-10-01T03:01:00.000Z", message: "All green."), to: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:01:00.000Z"))
        XCTAssertEqual(reader.lastMessage, "All green.")
        // Only the appended line was read.
        XCTAssertEqual(reader.bytesRead - before, Int64(F.taskComplete("2026-10-01T03:01:00.000Z", message: "All green.").utf8.count))

        try append(F.taskStarted("2026-10-01T03:02:00.000Z"), to: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.state, .running)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:02:00.000Z"))
    }

    func testPartialLastLineIsBufferedUntilItsNewline() throws {
        let url = try rollout(F.meta(id: id) + F.taskStarted("2026-10-01T03:00:01.000Z"))
        let reader = CodexRolloutReader(url: url)
        reader.update()
        XCTAssertEqual(reader.state, .running)

        let line = Data(F.taskComplete("2026-10-01T03:00:30.000Z", message: "Done in halves.").utf8)
        try append(line.prefix(57), to: url)
        XCTAssertEqual(reader.update(), .unchanged)
        XCTAssertEqual(reader.state, .running)
        XCTAssertEqual(reader.offset, try size(of: url), "the half line is consumed into the buffer, not re-read")

        try append(line.dropFirst(57), to: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.lastMessage, "Done in halves.")
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:00:30.000Z"))
    }

    func testHugeToolOutputStillBeingWrittenIsSkippedNotBuffered() throws {
        let url = try rollout(F.meta(id: id) + F.taskStarted("2026-10-01T03:00:01.000Z"))
        let reader = CodexRolloutReader(url: url)
        reader.update()

        let output = Data(F.responseItem("2026-10-01T03:00:02.000Z", size: 300_000).utf8)
        try append(output.dropLast(), to: url)   // no newline yet
        XCTAssertEqual(reader.update(), .unchanged)
        XCTAssertEqual(reader.pendingBytes, 0, "an unfinished tool-output line is dropped, not held")

        try append(Data("\n".utf8) + Data(F.taskComplete("2026-10-01T03:00:40.000Z", message: "ok").utf8), to: url)
        reader.update()
        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.lastMessage, "ok")
    }

    func testTruncatedFileStartsOver() throws {
        let url = try rollout(
            F.meta(id: id)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.agentMessage("2026-10-01T03:00:02.000Z", String(repeating: "long message ", count: 50))
            + F.taskComplete("2026-10-01T03:00:09.000Z", message: "first thread"))
        let reader = CodexRolloutReader(url: url)
        reader.update()
        XCTAssertEqual(reader.state, .idle)

        let other = "01a0c894-49df-7102-92b1-6cf77abbf88e"
        try Data((F.meta(id: other) + F.taskStarted("2026-10-01T04:00:00.000Z")).utf8).write(to: url)
        XCTAssertLessThan(try size(of: url), reader.offset)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.meta?.id, other)
        XCTAssertEqual(reader.state, .running)
        XCTAssertNil(reader.lastMessage)
    }

    func testReplacedFileStartsOverEvenAtTheSameSize() throws {
        let url = try rollout(F.meta(id: "aaaaaaaa-0000-0000-0000-000000000001") + F.taskStarted("2026-10-01T03:00:01.000Z"))
        let reader = CodexRolloutReader(url: url)
        reader.update()
        XCTAssertEqual(reader.state, .running)

        // Same length, different inode (renamed over it).
        let replacement = try rollout(F.meta(id: "aaaaaaaa-0000-0000-0000-000000000002") + F.taskStarted("2026-10-01T03:00:02.000Z"),
                                      name: "replacement.jsonl")
        XCTAssertEqual(try size(of: replacement), try size(of: url))
        XCTAssertEqual(rename(replacement.path, url.path), 0)

        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.meta?.id, "aaaaaaaa-0000-0000-0000-000000000002")
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:00:02.000Z"))
    }

    func testMissingFileThenCreated() throws {
        let url = tmp.appendingPathComponent("later.jsonl")
        let reader = CodexRolloutReader(url: url)
        XCTAssertEqual(reader.update(), .missing)
        XCTAssertNil(reader.meta)
        try Data((F.meta(id: id) + F.taskStarted("2026-10-01T03:00:01.000Z")).utf8).write(to: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.state, .running)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(reader.update(), .missing)
        XCTAssertNil(reader.meta)
    }

    func testUnfinishedMetaLineIsRetriedOnGrowthOnly() throws {
        let meta = Data(F.meta(id: id, padding: 20_000).utf8)
        let url = tmp.appendingPathComponent("young.jsonl")
        try meta.prefix(9000).write(to: url)
        let reader = CodexRolloutReader(url: url)
        XCTAssertEqual(reader.update(), .unchanged)
        XCTAssertNil(reader.meta)
        let afterFirstTry = reader.bytesRead
        XCTAssertEqual(reader.update(), .unchanged)
        XCTAssertEqual(reader.bytesRead, afterFirstTry, "an unchanged unfinished file is not re-read")

        try append(meta.dropFirst(9000), to: url)
        try append(F.taskStarted("2026-10-01T03:00:01.000Z"), to: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.meta?.id, id)
        XCTAssertEqual(reader.state, .running)
    }

    func testFileThatDoesNotStartWithMetaIsNotReread() throws {
        let url = try rollout(F.taskStarted("2026-10-01T03:00:01.000Z") + F.agentMessage("2026-10-01T03:00:02.000Z", "hi"))
        let reader = CodexRolloutReader(url: url)
        XCTAssertEqual(reader.update(), .unchanged)
        XCTAssertNil(reader.meta)
        let bytes = reader.bytesRead
        try append(F.taskComplete("2026-10-01T03:00:03.000Z", message: "x"), to: url)
        XCTAssertEqual(reader.update(), .unchanged)
        XCTAssertEqual(reader.bytesRead, bytes)
    }

    // MARK: Waiting

    func testApprovalRequestWaitsUntilTheAgentMovesOn() throws {
        let url = try rollout(F.meta(id: id) + F.taskStarted("2026-10-01T03:00:01.000Z") + F.approvalRequest("2026-10-01T03:00:04.000Z"))
        let reader = CodexRolloutReader(url: url)
        reader.update()
        XCTAssertEqual(reader.state, .waiting)
        XCTAssertEqual(reader.rawStatus, "exec_approval_request")
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:00:04.000Z"))

        try append(F.tokenCount("2026-10-01T03:00:05.000Z"), to: url)
        reader.update()
        XCTAssertEqual(reader.state, .waiting, "a token count is not the user answering")

        try append(F.responseItem("2026-10-01T03:01:00.000Z", type: "function_call_output"), to: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.state, .running)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:01:00.000Z"))
        XCTAssertEqual(reader.rawStatus, "function_call_output")

        try append(F.taskComplete("2026-10-01T03:02:00.000Z", message: "Pushed."), to: url)
        reader.update()
        XCTAssertEqual(reader.state, .idle)
    }

    func testOtherInputRequests() {
        XCTAssertTrue(CodexLine.isInputRequest("apply_patch_approval_request"))
        XCTAssertTrue(CodexLine.isInputRequest("request_user_input"))
        XCTAssertTrue(CodexLine.isInputRequest("elicitation_request"))
        XCTAssertFalse(CodexLine.isInputRequest("request_user_input_async"))
        XCTAssertFalse(CodexLine.isInputRequest("approval_request_resolved"))
    }

    // MARK: Robustness

    func testMalformedLinesChangeNothing() throws {
        var text = F.meta(id: id) + F.taskStarted("2026-10-01T03:00:01.000Z")
        text += "not json at all\n"
        text += "\n"
        text += "[]\n"
        text += #"{"timestamp":"2026-10-01T03:00:02.000Z","type":"event_msg","payload":"oops"}"# + "\n"
        text += #"{"timestamp":"2026-10-01T03:00:02.000Z","type":"event_msg","payload":{"type":"agent_message","message":42}}"# + "\n"
        text += #"{"timestamp":"2026-10-01T03:00:02.000Z","type":"event_msg","payload":{"type":"task_complete""# + "\n"
        text += #"{"timestamp":"2026-10-01T03:00:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","content":"x"}}}"# + "\n"
        let url = try rollout(text)
        try append(Data([0xFF, 0xFE, 0x22, 0x0A]), to: url)
        let reader = CodexRolloutReader(url: url)
        XCTAssertEqual(reader.update(), .changed)
        XCTAssertEqual(reader.state, .running)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:00:01.000Z"))
        XCTAssertNil(reader.lastMessage)

        // A boundary with an unusable timestamp still counts; its payload time stands in.
        try append(#"{"timestamp":"yesterday","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"ok","completed_at":1790000100}}"# + "\n", to: url)
        reader.update()
        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.stateSince, Date(timeIntervalSince1970: 1_790_000_100))
    }

    func testUnfamiliarKeyOrderIsStillUnderstood() throws {
        // Sorted keys put "payload" before "type": peek gives up, the parser does not.
        let sorted = #"{"payload":{"last_agent_message":"sorted","turn_id":"t1","type":"task_complete"},"timestamp":"2026-10-01T03:00:09.000Z","type":"event_msg"}"#
        XCTAssertNil(CodexLine.peek(Data(sorted.utf8)))
        let url = try rollout(F.meta(id: id) + F.taskStarted("2026-10-01T03:00:01.000Z") + sorted + "\n")
        let reader = CodexRolloutReader(url: url)
        reader.update()
        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.lastMessage, "sorted")
    }

    func testPeekReadsTheRealLayout() {
        let item = Data(F.itemCompleted("2026-10-01T03:00:04.000Z", item: "AgentMessage", text: "hi").utf8)
        XCTAssertEqual(CodexLine.peek(item), CodexLine.Kind(type: "event_msg", payloadType: "item_completed", itemType: "AgentMessage"))
        XCTAssertEqual(CodexLine.reading(for: CodexLine.peek(item)), .parse)

        let command = Data(F.event("item_completed", "2026-10-01T03:00:04.000Z", #""thread_id":"th","item":{"type":"CommandExecution"}"#).utf8)
        XCTAssertEqual(CodexLine.reading(for: CodexLine.peek(command)), .skip)

        let meta = Data(F.meta(id: id).utf8)
        XCTAssertEqual(CodexLine.peek(meta), CodexLine.Kind(type: "session_meta"))
        XCTAssertEqual(CodexLine.reading(for: CodexLine.peek(meta)), .skip, "later session_meta lines are someone else's")

        XCTAssertEqual(CodexLine.reading(for: CodexLine.peek(Data(F.responseItem("2026-10-01T03:00:04.000Z").utf8))), .progress)
        XCTAssertEqual(CodexLine.timestamp(in: item), F.date("2026-10-01T03:00:04.000Z"))
    }

    func testTimestampsWithAndWithoutFractions() {
        XCTAssertEqual(CodexLine.date("2026-09-21T07:23:09.949Z")?.timeIntervalSince1970 ?? 0, 1_789_975_389.949, accuracy: 0.0005)
        XCTAssertEqual(CodexLine.date("2026-09-22T10:06:02.283803Z")?.timeIntervalSince1970 ?? 0, 1_790_071_562.283803, accuracy: 0.0005)
        XCTAssertEqual(CodexLine.date("2026-09-21T07:23:09Z"), Date(timeIntervalSince1970: 1_789_975_389))
        XCTAssertEqual(CodexLine.date("2026-09-21T15:23:09.949+08:00")?.timeIntervalSince1970 ?? 0, 1_789_975_389.949, accuracy: 0.0005)
        XCTAssertNil(CodexLine.date("yesterday"))
    }

    func testTextHelpers() {
        XCTAssertEqual(CodexText.request(in: "# Context from my IDE setup:\n## Open tabs:\n- x\n\n## My request for Codex:\n  do it  "), "do it")
        XCTAssertEqual(CodexText.request(in: "plain ## My request:\nnot wrapped"), "plain ## My request:\nnot wrapped")
        XCTAssertNil(CodexText.titleText("# Context from my IDE setup:\n\n## Open tabs:\n- Inve"))
        XCTAssertEqual(CodexText.titleText("Audit finance inventory procurement"), "Audit finance inventory procurement")
        XCTAssertNil(CodexText.preview(" \n "))
        let long = CodexText.preview(String(repeating: "é", count: 2_500))
        XCTAssertEqual(long?.count, CodexText.maxPreviewCharacters)
        XCTAssertEqual(long?.last, "…")
    }

    // MARK: Big files

    func testBigFileIsReadFromItsTailAndHeadOnly() throws {
        let prompt = "# Context from my IDE setup:\n\n## Open tabs:\n- x.swift\n\n## My request:\nship the codex source"
        let text = F.meta(id: id, padding: 20_000)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.userMessage("2026-10-01T03:00:01.100Z", prompt)
            + F.filler("2026-10-01T03:00:02.000Z", bytes: 3_000_000)
            + F.agentMessage("2026-10-01T03:30:00.000Z", "Wrapping up.")
            + F.taskComplete("2026-10-01T03:30:05.000Z", message: "Shipped.")
        let url = try rollout(text)
        let reader = CodexRolloutReader(url: url)
        reader.update()

        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:30:05.000Z"))
        XCTAssertEqual(reader.lastMessage, "Shipped.")
        XCTAssertEqual(reader.firstUserMessage, "ship the codex source")
        let fileSize = try size(of: url)
        XCTAssertGreaterThan(fileSize, 3_000_000)
        XCTAssertLessThan(reader.bytesRead, 1_200_000, "meta + 512 KB tail + 512 KB head, not \(fileSize) bytes")
    }

    func testGiantLastLineAfterTheTurnEnded() throws {
        // Real shape: a 701 KB item written 7 minutes after task_complete left
        // no complete line in the last 512 KB.
        let text = F.meta(id: id, padding: 20_000)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.userMessage("2026-10-01T03:00:01.100Z", "audit the ledger")
            + F.filler("2026-10-01T03:00:02.000Z", bytes: 900_000)
            + F.agentMessage("2026-10-01T03:20:00.000Z", "Final notes.")
            + F.taskComplete("2026-10-01T03:20:01.000Z", message: nil)
            + F.responseItem("2026-10-01T03:27:00.000Z", size: 701_000)
        let url = try rollout(text)
        let reader = CodexRolloutReader(url: url)
        reader.update()

        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:20:01.000Z"))
        XCTAssertEqual(reader.rawStatus, "task_complete")
        XCTAssertEqual(reader.turnEnd, .completed, "found before the tail")
        // The turn ended with a null message; the agent's last words sit before the tail.
        XCTAssertEqual(reader.lastMessage, "Final notes.")
        XCTAssertEqual(reader.firstUserMessage, "audit the ledger")
        let fileSize = try size(of: url)
        XCTAssertLessThan(reader.bytesRead, fileSize * 3 / 4, "read \(reader.bytesRead) of \(fileSize) bytes")

        try append(F.taskStarted("2026-10-01T03:30:00.000Z"), to: url)
        reader.update()
        XCTAssertEqual(reader.state, .running)
    }

    func testLongTurnWithNoBoundaryInTheTailIsRunningSinceItsStart() throws {
        let text = F.meta(id: id)
            + F.taskComplete("2026-10-01T02:00:00.000Z", message: "earlier turn")
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.filler("2026-10-01T03:00:02.000Z", bytes: 1_500_000)
            + F.agentMessage("2026-10-01T03:40:00.000Z", "Still going.")
        let url = try rollout(text)
        let reader = CodexRolloutReader(url: url)
        reader.update()

        XCTAssertEqual(reader.state, .running)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T03:00:01.000Z"))
        XCTAssertEqual(reader.rawStatus, "task_started")
        XCTAssertEqual(reader.lastMessage, "Still going.")
    }

    func testNoBoundaryWithinTheSearchBudgetMeansMidTurn() throws {
        let text = F.meta(id: id)
            + F.taskStarted("2026-10-01T03:00:01.000Z")
            + F.filler("2026-10-01T03:00:02.000Z", bytes: 2_000_000)
        let url = try rollout(text)
        let reader = CodexRolloutReader(url: url)
        reader.boundarySearchBytes = 256 * 1024
        reader.update()

        XCTAssertEqual(reader.state, .running)
        XCTAssertNil(reader.stateSince)
        XCTAssertNil(reader.turnEnd)
        XCTAssertLessThan(reader.bytesRead, 2_000_000)
    }

    func testBigThreadThatNeverStartedATurnIsIdle() throws {
        let text = F.meta(id: id, time: "2026-10-01T02:00:00.000Z")
            + F.filler("2026-10-01T02:00:01.000Z", bytes: 700_000, lineSize: 1000)
        let url = try rollout(text)
        let reader = CodexRolloutReader(url: url)
        reader.update()
        XCTAssertEqual(reader.state, .idle)
        XCTAssertEqual(reader.stateSince, F.date("2026-10-01T02:00:00.000Z"))
    }
}
