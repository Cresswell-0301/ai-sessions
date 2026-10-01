import Darwin
import Foundation

// MARK: - Session meta

/// Who started a Codex thread, from the `session_meta` first line of its
/// rollout. Later `session_meta` lines are ignored on purpose: a sub-agent's
/// rollout repeats its parent's meta as line 2, and a reloaded thread writes
/// its own again mid-file (both seen in real rollouts).
public struct CodexSessionMeta: Equatable, Sendable {
    public var id: String
    public var cwd: String?
    /// "codex_vscode", "codex_cli_rs", "codex_exec", …
    public var originator: String?
    /// The `source` field: "vscode", "cli", "exec", …; "subagent" for the
    /// object form `{"subagent": …}` (spawned workers and guardian reviews);
    /// "unknown" when absent.
    public var sourceKind: String
    /// "user", "subagent", "guardian_review", …
    public var threadSource: String?
    public var cliVersion: String?

    public init(id: String, cwd: String? = nil, originator: String? = nil, sourceKind: String = "unknown",
                threadSource: String? = nil, cliVersion: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.originator = originator
        self.sourceKind = sourceKind
        self.threadSource = threadSource
        self.cliVersion = cliVersion
    }

    /// Parses a rollout's first line; nil unless it is a `session_meta` with an id.
    public init?(line: Data) {
        guard let object = CodexLine.object(line), object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = (payload["id"] as? String) ?? (payload["session_id"] as? String), !id.isEmpty
        else { return nil }
        self.init(id: id,
                  cwd: payload["cwd"] as? String,
                  originator: payload["originator"] as? String,
                  sourceKind: Self.sourceKind(of: payload["source"]),
                  threadSource: payload["thread_source"] as? String,
                  cliVersion: payload["cli_version"] as? String)
    }

    /// False for `codex exec` runs and sub-agents: automation nobody typed into.
    public var isInteractive: Bool {
        originator != "codex_exec" && sourceKind != "subagent" && sourceKind != "exec"
    }

    /// A thread has no process of its own (one app-server per editor window
    /// hosts them all), so the host carries no pid; the router finds the window.
    public var host: SessionHost {
        guard let originator else { return .unknown }
        if originator == "codex_vscode" { return .vscode(extensionHostPid: nil) }
        if originator.hasPrefix("codex_cli") { return .terminal(appPid: nil) }
        return .unknown
    }

    static func sourceKind(of source: Any?) -> String {
        if let name = source as? String { return name.isEmpty ? "unknown" : name }
        guard let object = source as? [String: Any] else { return "unknown" }
        if object["subagent"] != nil { return "subagent" }
        if object.count == 1, let key = object.keys.first { return key }
        return "other"
    }
}

// MARK: - Rollout reader

/// Follows one rollout file: the meta line once, then only the bytes appended
/// since the last `update()`. A first open of a big file reads its last
/// 512 KB for the current state (looking further back, within a budget, only
/// for what those lack) and at most 512 KB after the meta line for the first
/// prompt; never the whole file. Rollouts reach 24 MB.
public final class CodexRolloutReader {
    public enum Update: Equatable, Sendable {
        case unchanged
        /// State, preview or first prompt changed (or the meta became readable).
        case changed
        /// The file is gone or not a regular file.
        case missing
    }

    public static let tailBytes: Int64 = 512 * 1024
    static let headScanBytes: Int64 = 512 * 1024
    static let readChunkBytes = 1 << 20
    /// Steps of the searches before the tail; what they look for is usually close.
    static let searchChunkBytes = 256 * 1024
    /// Real meta lines are ~20 KB (they embed the base instructions).
    static let maxMetaLineBytes = 1 << 20
    static let maxLineBytes = 16 << 20

    public let url: URL
    public private(set) var meta: CodexSessionMeta?
    /// Modification time from the last `update()`.
    public private(set) var modifiedAt: Date?
    /// Bytes consumed so far; a line still being written is buffered, not re-read.
    public private(set) var offset: Int64 = 0

    public var state: ActivityState { activity.state }
    /// When `state` was entered: the timestamp of the event that set it.
    public var stateSince: Date? { activity.stateSince }
    /// The event type that set `state` ("task_started", "task_complete", …).
    public var rawStatus: String? { activity.rawStatus }
    /// How the last turn ended, while `state` is idle because of it:
    /// `task_complete` completed it, `turn_aborted` (Stop, or Codex shutting
    /// the turn down) interrupted it. nil otherwise.
    public var turnEnd: TurnEnd? { activity.turnEnd }
    public var lastMessage: String? { activity.lastMessage }
    /// The user's first prompt, without the IDE context Codex prepends to it.
    public var firstUserMessage: String? { activity.firstUserMessage }

    /// How far before the tail a first open searches for the last turn boundary
    /// (and, when the tail has none, the latest agent message).
    var boundarySearchBytes: Int64 = 8 << 20
    /// Bytes read from disk so far; tests check that big files are not read whole.
    private(set) var bytesRead: Int64 = 0
    /// Size of the buffered, unfinished last line.
    var pendingBytes: Int { pending.count }

    private var activity = CodexActivity()
    private var identity: FileIdentity?
    private var pending = Data()
    /// Inside a line that does not matter (or no longer fits): drop bytes until its newline.
    private var skippingLine = false
    /// The first line is complete but not a `session_meta`: wait for a replacement.
    private var unusable = false
    /// Size at the last attempt to read the meta line, so an unfinished one is retried only on growth.
    private var attemptedSize: Int64?

    public init(url: URL) {
        self.url = url
    }

    /// Stats the file and consumes whatever was appended; starts over when the
    /// file was replaced or truncated.
    @discardableResult
    public func update() -> Update {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            if identity != nil || meta != nil { reset() }
            modifiedAt = nil
            return .missing
        }
        modifiedAt = Self.date(st.st_mtimespec)
        let size = Int64(st.st_size)
        if let identity, identity != FileIdentity(st) || size < offset {
            reset()
        }
        if meta == nil {
            guard !unusable, attemptedSize != size else { return .unchanged }
            return load() ? .changed : .unchanged
        }
        guard size > offset, let fd = openFile() else { return .unchanged }
        defer { close(fd) }
        let before = activity
        consume(fd, from: offset, to: size)
        return activity == before ? .unchanged : .changed
    }

    // MARK: First open

    private func load() -> Bool {
        guard let fd = openFile() else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        let size = Int64(st.st_size)
        attemptedSize = size
        let first: Data
        let metaEnd: Int64
        switch readFirstLine(fd, size: size) {
        case .unfinished:
            return false
        case .tooLong:
            identity = FileIdentity(st)
            offset = size
            unusable = true
            return false
        case .line(let line, let end):
            first = line
            metaEnd = end
        }
        identity = FileIdentity(st)
        offset = size
        guard let meta = CodexSessionMeta(line: first) else {
            unusable = true
            return false
        }
        self.meta = meta
        activity = CodexActivity(since: CodexLine.timestamp(in: first))
        if size - metaEnd <= Self.tailBytes {
            activity.capturesFirstUserMessage = true
            consume(fd, from: metaEnd, to: size)
        } else {
            readTail(fd, metaEnd: metaEnd, size: size)
            activity.firstUserMessage = scanFirstUserMessage(fd, from: metaEnd, to: min(size, metaEnd + Self.headScanBytes))
        }
        return true
    }

    private enum FirstLine {
        case line(Data, end: Int64)
        case unfinished
        case tooLong
    }

    private func readFirstLine(_ fd: Int32, size: Int64) -> FirstLine {
        var head = Data()
        while head.count < Self.maxMetaLineBytes, Int64(head.count) < size {
            let count = Int(min(Int64(64 * 1024), size - Int64(head.count)))
            guard let chunk = read(fd, at: Int64(head.count), count: count), !chunk.isEmpty else { return .unfinished }
            let searchFrom = head.endIndex
            head.append(chunk)
            if let newline = CodexBytes.newline(in: head, from: searchFrom) {
                return .line(head[..<newline], end: Int64(newline) + 1)
            }
        }
        return head.count >= Self.maxMetaLineBytes ? .tooLong : .unfinished
    }

    /// The state of a big file from its last 512 KB. What the tail lacks —
    /// the turn boundary in a long turn or behind one huge line (a real
    /// rollout ends in a 701 KB line written after its last `task_complete`),
    /// or any agent message — is looked up before it, then everything applies
    /// in file order.
    private func readTail(_ fd: Int32, metaEnd: Int64, size: Int64) {
        let windowStart = size - Self.tailBytes
        // One byte before the window: a newline there means the window starts on a line.
        guard let window = read(fd, at: windowStart - 1, count: Int(size - windowStart + 1)) else { return }
        // The line straddling the window start keeps its type fields in its
        // first `peekBytes`; the search before the tail reaches that far into it.
        var searchEnd = min(size, windowStart + Int64(CodexLine.peekBytes))
        var events: [CodexEvent] = []
        var rest = Data()
        if let firstNewline = CodexBytes.newline(in: window, from: window.startIndex) {
            searchEnd = min(searchEnd, windowStart + Int64(firstNewline - window.startIndex))
            let body = window[(firstNewline + 1)...]
            let end = CodexBytes.forEachLine(in: body) { line in
                if !line.isEmpty, let event = CodexLine.event(in: line, wantsProgress: true) { events.append(event) }
                return true
            }
            rest = body[end...]
        } else {
            skippingLine = true   // the whole window is the middle of one huge line
        }
        let earlier = searchBack(fd, from: metaEnd, before: searchEnd,
                                 wantBoundary: !events.contains(where: \.isBoundary),
                                 wantMessage: !events.contains(where: \.carriesMessage))
        if let message = earlier.message, !earlier.messageIsNewer { activity.apply(message) }
        if let boundary = earlier.boundary {
            activity.apply(boundary)
        } else if earlier.gaveUp {
            activity.assumeMidTurn()
        }
        if let message = earlier.message, earlier.messageIsNewer { activity.apply(message) }
        for event in events { activity.apply(event) }
        if !rest.isEmpty {
            pending = Data(rest)
            trimPending()
        }
    }

    /// What lies before the tail. No boundary and no budget exhaustion means
    /// the search reached the meta line: the thread never started a turn.
    private struct Earlier {
        var boundary: CodexEvent?
        /// The latest agent message, from either side of `boundary`.
        var message: CodexEvent?
        var messageIsNewer = false
        /// `boundarySearchBytes` ran out while a boundary was still wanted.
        var gaveUp = false
    }

    /// Walks back from `end` looking for the wanted lines by byte pattern —
    /// cheap even through multi-MB lines, and the quotes in the patterns cannot
    /// appear unescaped inside a JSON string — parsing only the line around a match.
    private func searchBack(_ fd: Int32, from floor: Int64, before end: Int64,
                            wantBoundary: Bool, wantMessage: Bool) -> Earlier {
        var earlier = Earlier()
        var wantBoundary = wantBoundary
        var wantMessage = wantMessage
        let overlap = CodexLine.longestMarker - 1
        var limit = end   // a match must start before this
        var low = end     // `data` holds the bytes from here on
        var data = Data()
        var scanned: Int64 = 0
        while wantBoundary || wantMessage {
            let markers = (wantBoundary ? CodexLine.boundaryMarkers : []) + (wantMessage ? CodexLine.agentMessageMarkers : [])
            guard let hit = CodexBytes.lastMatch(of: markers, in: data, startingBefore: Int(limit - low)) else {
                // Nothing left in this chunk: load the one before it, keeping
                // enough of this one for a pattern that spans the seam.
                guard low > floor else { break }
                let budget = boundarySearchBytes - scanned
                guard budget > 0 else {
                    earlier.gaveUp = wantBoundary
                    break
                }
                let newLow = max(floor, low - min(Int64(Self.searchChunkBytes), budget))
                let count = scanned == 0 ? Int(end - newLow) + overlap : Int(low - newLow)
                guard let fresh = read(fd, at: newLow, count: count) else {
                    earlier.gaveUp = wantBoundary
                    break
                }
                data = scanned == 0 ? fresh : fresh + data.prefix(overlap)
                scanned += low - newLow
                limit = min(limit, low)
                low = newLow
                continue
            }
            let position = low + Int64(hit)
            limit = position
            guard let line = lineContaining(fd, position: position, floor: floor),
                  let event = CodexLine.event(in: line, wantsProgress: false) else { continue }
            if wantBoundary, event.isBoundary {
                earlier.boundary = event
                wantBoundary = false
                if event.carriesMessage { wantMessage = false }
            } else if wantMessage, case .agentMessage = event.change, event.carriesMessage {
                earlier.message = event
                earlier.messageIsNewer = earlier.boundary == nil
                wantMessage = false
            }
        }
        return earlier
    }

    /// The line around a marker at `position`. Type fields sit in a line's
    /// first ~100 bytes; a match deeper than `peekBytes` into its line is not one.
    private func lineContaining(_ fd: Int32, position: Int64, floor: Int64) -> Data? {
        let back = max(floor, position - Int64(CodexLine.peekBytes))
        guard let before = read(fd, at: back, count: Int(position - back)) else { return nil }
        let start: Int64
        if let newline = before.lastIndex(of: 0x0A) {
            start = back + Int64(newline - before.startIndex) + 1
        } else if back == floor {
            start = floor
        } else {
            return nil
        }
        var line = Data()
        var cursor = start
        while line.count <= Self.maxLineBytes {
            guard let chunk = read(fd, at: cursor, count: 16 * 1024), !chunk.isEmpty else { return line }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[..<newline])
                return line
            }
            line.append(chunk)
            cursor += Int64(chunk.count)
        }
        return nil
    }

    /// The first prompt of a big file, read forward in steps from the meta
    /// line (median offset in real rollouts: 80 KB, behind injected context).
    private func scanFirstUserMessage(_ fd: Int32, from start: Int64, to end: Int64) -> String? {
        var unscanned = Data()
        var position = start
        while position < end {
            guard let chunk = read(fd, at: position, count: Int(min(Int64(Self.searchChunkBytes), end - position))),
                  !chunk.isEmpty else { return nil }
            position += Int64(chunk.count)
            unscanned.append(chunk)
            var found: String?
            let scannedUpTo = CodexBytes.forEachLine(in: unscanned) { line in
                guard let kind = CodexLine.peek(line), CodexLine.isUserMessage(kind),
                      case .userMessage(let text)? = CodexLine.event(in: line, wantsProgress: false)?.change
                else { return true }
                found = CodexText.preview(CodexText.request(in: text))
                return false
            }
            if let found { return found }
            unscanned = Data(unscanned[scannedUpTo...])
        }
        return nil
    }

    // MARK: Appended bytes

    private func consume(_ fd: Int32, from start: Int64, to end: Int64) {
        var position = start
        while position < end {
            let count = Int(min(Int64(Self.readChunkBytes), end - position))
            guard let chunk = read(fd, at: position, count: count), !chunk.isEmpty else { break }
            feed(chunk)
            position += Int64(chunk.count)
        }
        offset = position
    }

    /// Splits appended bytes into lines; the unterminated rest stays buffered
    /// until its newline arrives.
    private func feed(_ chunk: Data) {
        var lineStart = chunk.startIndex
        while let newline = CodexBytes.newline(in: chunk, from: lineStart) {
            if skippingLine {
                skippingLine = false
            } else if pending.isEmpty {
                handle(chunk[lineStart..<newline])
            } else {
                pending.append(chunk[lineStart..<newline])
                handle(pending)
                pending = Data()
            }
            lineStart = newline + 1
        }
        guard !skippingLine, lineStart < chunk.endIndex else { return }
        pending.append(chunk[lineStart...])
        trimPending()
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty,
              let event = CodexLine.event(in: line, wantsProgress: activity.state == .waiting) else { return }
        activity.apply(event)
    }

    /// Keeps a line still being written only while it may matter: tool output
    /// lines run to megabytes and are never parsed.
    private func trimPending() {
        guard pending.count > CodexLine.peekBytes else { return }
        let keep: Bool
        switch CodexLine.reading(for: CodexLine.peek(pending)) {
        case .parse:
            keep = pending.count <= Self.maxLineBytes
        case .parseIfSmall:
            keep = pending.count <= CodexLine.maxUnpeekedBytes
        case .progress:
            if activity.state == .waiting, let event = CodexLine.event(in: pending, wantsProgress: true) {
                activity.apply(event)
            }
            keep = false
        case .skip:
            keep = false
        }
        if !keep {
            pending = Data()
            skippingLine = true
        }
    }

    // MARK: Files

    private func reset() {
        meta = nil
        activity = CodexActivity()
        identity = nil
        pending = Data()
        skippingLine = false
        unusable = false
        attemptedSize = nil
        offset = 0
    }

    private func openFile() -> Int32? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    private func read(_ fd: Int32, at position: Int64, count: Int) -> Data? {
        guard let data = CodexBytes.read(fd, at: position, count: count) else { return nil }
        bytesRead += Int64(data.count)
        return data
    }

    static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ st: stat) {
            device = st.st_dev
            inode = st.st_ino
        }
    }
}

// MARK: - State machine

/// One rollout event, as far as the session state is concerned.
struct CodexEvent: Equatable {
    enum Change: Equatable {
        case turnStarted
        case turnComplete(lastAgentMessage: String?)
        case turnAborted
        case agentMessage(String)
        case userMessage(String)
        /// An approval request or a question that blocks the turn.
        case needsInput
        /// Any response item: the agent moved on after a request for input.
        case progress
    }

    var change: Change
    var timestamp: Date?
    /// The rollout's own name for the event ("task_complete", …).
    var rawType: String

    var isBoundary: Bool {
        switch change {
        case .turnStarted, .turnComplete, .turnAborted: return true
        default: return false
        }
    }

    /// Sets the preview: an agent message, or a turn end with its final message.
    var carriesMessage: Bool {
        switch change {
        case .agentMessage(let text): return CodexText.preview(text) != nil
        case .turnComplete(let message): return CodexText.preview(message) != nil
        default: return false
        }
    }
}

/// Folds events, in file order, into the thread's current state.
struct CodexActivity: Equatable {
    var state: ActivityState = .idle
    var stateSince: Date?
    var rawStatus: String?
    /// Set by the boundary that made the thread idle; cleared by anything
    /// that makes it busy again.
    var turnEnd: TurnEnd?
    var lastMessage: String?
    var firstUserMessage: String?
    /// Every line since the meta line has been seen, so the next prompt is the first.
    var capturesFirstUserMessage = false

    /// A thread that has not started a turn is idle since it was created.
    init(since created: Date? = nil) {
        stateSince = created
    }

    mutating func apply(_ event: CodexEvent) {
        switch event.change {
        case .turnStarted:
            enter(.running, event)
        case .turnComplete(let message):
            enter(.idle, event)
            turnEnd = .completed
            if let message = CodexText.preview(message) { lastMessage = message }
        case .turnAborted:
            // Every abort reason means the turn did not finish its answer.
            enter(.idle, event)
            turnEnd = .interrupted
        case .agentMessage(let text):
            if let text = CodexText.preview(text) { lastMessage = text }
        case .userMessage(let text):
            if capturesFirstUserMessage, firstUserMessage == nil {
                firstUserMessage = CodexText.preview(CodexText.request(in: text))
            }
        case .needsInput:
            enter(.waiting, event)
        case .progress:
            if state == .waiting { enter(.running, event) }
        }
    }

    /// No boundary within reach while the thread kept writing: a turn longer
    /// than the search window. When it began is unknown.
    mutating func assumeMidTurn() {
        state = .running
        stateSince = nil
        rawStatus = nil
        turnEnd = nil
    }

    private mutating func enter(_ newState: ActivityState, _ event: CodexEvent) {
        state = newState
        stateSince = event.timestamp
        rawStatus = event.rawType
        turnEnd = nil
    }
}

// MARK: - Lines

/// Reads single rollout lines, `{"timestamp","type","payload"}`. Lines reach
/// megabytes (tool output, compactions) and only a few kinds matter, so the
/// type fields are read from the first bytes and only those lines are parsed.
enum CodexLine {
    /// The `type` fields of a line.
    struct Kind: Equatable {
        var type: String
        var payloadType: String? = nil
        /// For `item_completed`: "AgentMessage", "UserMessage", "CommandExecution", …
        var itemType: String? = nil
    }

    enum Reading: Equatable {
        case skip
        /// A small event line the state machine uses.
        case parse
        /// A response item: only its timestamp, and only while waiting for input.
        case progress
        /// A layout `peek` does not know: parse it unless it is big.
        case parseIfSmall
    }

    /// The type fields sit in a line's first ~250 bytes.
    static let peekBytes = 4096
    static let maxUnpeekedBytes = 64 * 1024
    static let boundaryTypes: Set<String> = ["task_started", "task_complete", "turn_aborted"]

    private static let payloadKey = Array(#""payload":"#.utf8)
    private static let typeKey = Array(#""type":""#.utf8)
    private static let payloadTypeKey = Array(#""payload":{"type":""#.utf8)
    private static let itemTypeKey = Array(#""item":{"type":""#.utf8)
    private static let timestampKey = Array(#""timestamp":""#.utf8)
    static let boundaryMarkers: [[UInt8]] = boundaryTypes.sorted().map { Array(#""payload":{"type":"\#($0)""#.utf8) }
    static let agentMessageMarkers: [[UInt8]] = [Array(#""payload":{"type":"agent_message""#.utf8),
                                                 Array(#""item":{"type":"AgentMessage""#.utf8)]
    static let longestMarker = (boundaryMarkers + agentMessageMarkers).map(\.count).max() ?? 1
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// The type fields from the first bytes, without parsing; nil when the
    /// line does not have the usual `…"type":…,"payload":…` layout.
    static func peek(_ line: Data) -> Kind? {
        line.withUnsafeBytes { raw -> Kind? in
            let end = min(raw.count, peekBytes)
            guard let payload = CodexBytes.find(payloadKey, in: raw, from: 0, to: end),
                  let type = CodexBytes.string(after: typeKey, in: raw, from: 0, to: payload, limit: end)
            else { return nil }
            var kind = Kind(type: type)
            if CodexBytes.hasPrefix(payloadTypeKey, in: raw, at: payload),
               let payloadType = CodexBytes.string(after: payloadTypeKey, in: raw, from: payload, to: end, limit: end) {
                kind.payloadType = payloadType
                if payloadType == "item_completed" {
                    kind.itemType = CodexBytes.string(after: itemTypeKey, in: raw, from: payload, to: end, limit: end)
                }
            }
            return kind
        }
    }

    static func reading(for kind: Kind?) -> Reading {
        guard let kind else { return .parseIfSmall }
        switch kind.type {
        case "response_item":
            return .progress
        case "event_msg":
            guard let payloadType = kind.payloadType else { return .parseIfSmall }
            switch payloadType {
            case "task_started", "task_complete", "turn_aborted", "agent_message", "user_message":
                return .parse
            case "item_completed":
                switch kind.itemType {
                case "AgentMessage"?, "UserMessage"?: return .parse
                case nil: return .parseIfSmall
                default: return .skip
                }
            default:
                return isInputRequest(payloadType) ? .parse : .skip
            }
        default:
            return .skip
        }
    }

    static func isUserMessage(_ kind: Kind) -> Bool {
        kind.type == "event_msg"
            && (kind.payloadType == "user_message" || (kind.payloadType == "item_completed" && kind.itemType == "UserMessage"))
    }

    /// Approval prompts and questions block the turn on the user. Current
    /// Codex does not persist them (none in 139 real rollouts); other builds may.
    static func isInputRequest(_ payloadType: String) -> Bool {
        payloadType.hasSuffix("approval_request") || payloadType == "request_user_input"
            || payloadType == "elicitation_request"
    }

    /// The event a line carries, parsing it only when needed. `wantsProgress`
    /// is false outside the waiting state, where response items change nothing.
    static func event(in line: Data, wantsProgress: Bool) -> CodexEvent? {
        let kind = peek(line)
        switch reading(for: kind) {
        case .skip:
            return nil
        case .progress:
            guard wantsProgress else { return nil }
            return CodexEvent(change: .progress, timestamp: timestamp(in: line),
                              rawType: kind?.payloadType ?? "response_item")
        case .parse:
            return object(line).flatMap(event(from:))
        case .parseIfSmall:
            return line.count <= maxUnpeekedBytes ? object(line).flatMap(event(from:)) : nil
        }
    }

    static func event(from object: [String: Any]) -> CodexEvent? {
        guard let type = object["type"] as? String else { return nil }
        let timestamp = (object["timestamp"] as? String).flatMap(date)
        let payload = object["payload"] as? [String: Any]
        let payloadType = payload?["type"] as? String
        if type == "response_item" {
            return CodexEvent(change: .progress, timestamp: timestamp, rawType: payloadType ?? type)
        }
        guard type == "event_msg", let payload, let payloadType else { return nil }
        let change: CodexEvent.Change
        switch payloadType {
        case "task_started":
            change = .turnStarted
        case "task_complete":
            change = .turnComplete(lastAgentMessage: payload["last_agent_message"] as? String)
        case "turn_aborted":
            change = .turnAborted
        case "agent_message":
            guard let message = payload["message"] as? String else { return nil }
            change = .agentMessage(message)
        case "user_message":
            guard let message = payload["message"] as? String else { return nil }
            change = .userMessage(message)
        case "item_completed":
            // Builds before 0.154.0-alpha.6.2 log messages only as completed items.
            guard let item = payload["item"] as? [String: Any], let text = itemText(item) else { return nil }
            switch item["type"] as? String {
            case "AgentMessage": change = .agentMessage(text)
            case "UserMessage": change = .userMessage(text)
            default: return nil
            }
        default:
            guard isInputRequest(payloadType) else { return nil }
            change = .needsInput
        }
        return CodexEvent(change: change, timestamp: timestamp ?? payloadTime(payload), rawType: payloadType)
    }

    /// The line's own `timestamp`, read from its first bytes.
    static func timestamp(in line: Data) -> Date? {
        line.withUnsafeBytes { raw -> Date? in
            let end = min(raw.count, peekBytes)
            return CodexBytes.string(after: timestampKey, in: raw, from: 0, to: end, limit: end).flatMap(date)
        }
    }

    /// ISO-8601 with or without fractional seconds ("2026-09-21T07:23:09.949Z").
    static func date(_ text: String) -> Date? {
        try? dateStyle.parse(text)
    }

    private static func itemText(_ item: [String: Any]) -> String? {
        guard let content = item["content"] as? [Any] else { return nil }
        let parts = content.compactMap { ($0 as? [String: Any])?["text"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// `task_*` payloads also carry epoch seconds; used when the line's own timestamp is unusable.
    private static func payloadTime(_ payload: [String: Any]) -> Date? {
        for key in ["completed_at", "started_at"] {
            if let seconds = (payload[key] as? NSNumber)?.doubleValue, seconds > 0 {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }
}

// MARK: - Text

enum CodexText {
    /// Same cap as the Claude transcript previews.
    static let maxPreviewCharacters = 2_000
    /// The VS Code extension sends open tabs and selections ahead of the prompt
    /// under this heading; the user's words follow "## My request:" (older
    /// builds: "## My request for Codex:").
    static let ideContextHeader = "# Context from my IDE setup:"
    private static let requestHeadings = ["\n## My request:", "\n## My request for Codex:"]

    /// Trimmed and capped; nil when nothing is left.
    static func preview(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.utf8.count <= maxPreviewCharacters || trimmed.count <= maxPreviewCharacters { return trimmed }
        return String(trimmed.prefix(maxPreviewCharacters - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The user's own words in a prompt the IDE wrapped in context.
    static func request(in text: String) -> String {
        guard text.hasPrefix(ideContextHeader) else { return text }
        let headings = requestHeadings.compactMap { text.range(of: $0) }
        guard let first = headings.min(by: { $0.lowerBound < $1.lowerBound }) else { return text }
        let request = text[first.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return request.isEmpty ? text : request
    }

    /// A stored thread title, unless it is only IDE context (older Codex
    /// builds stored the raw first prompt as the title).
    static func titleText(_ title: String) -> String? {
        let text = request(in: title)
        return text.hasPrefix(ideContextHeader) ? nil : text
    }
}

// MARK: - Bytes

enum CodexBytes {
    static func find(_ needle: [UInt8], in raw: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Int? {
        guard start >= 0, end <= raw.count, end - start >= needle.count, !needle.isEmpty,
              let base = raw.baseAddress else { return nil }
        return needle.withUnsafeBytes { little -> Int? in
            guard let hit = memmem(base + start, end - start, little.baseAddress, needle.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    static func findLast(_ needle: [UInt8], in raw: UnsafeRawBufferPointer, to end: Int) -> Int? {
        var last: Int?
        var from = 0
        while let hit = find(needle, in: raw, from: from, to: end) {
            last = hit
            from = hit + 1
        }
        return last
    }

    /// Offset of the last match of any of `needles` that starts before `limit`.
    static func lastMatch(of needles: [[UInt8]], in data: Data, startingBefore limit: Int) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            needles.compactMap { needle in
                findLast(needle, in: raw, to: min(raw.count, limit + needle.count - 1))
            }.max()
        }
    }

    static func hasPrefix(_ prefix: [UInt8], in raw: UnsafeRawBufferPointer, at index: Int) -> Bool {
        guard index >= 0, index + prefix.count <= raw.count else { return false }
        for (k, byte) in prefix.enumerated() where raw[index + k] != byte { return false }
        return true
    }

    /// The characters between `key` (found within `start..<end`, ending in an
    /// opening quote) and the closing quote; nil when escaped or cut off.
    static func string(after key: [UInt8], in raw: UnsafeRawBufferPointer, from start: Int, to end: Int, limit: Int) -> String? {
        guard let hit = find(key, in: raw, from: start, to: end) else { return nil }
        let valueStart = hit + key.count
        var i = valueStart
        while i < min(limit, raw.count) {
            switch raw[i] {
            case UInt8(ascii: "\""):
                return String(decoding: UnsafeRawBufferPointer(rebasing: raw[valueStart..<i]), as: UTF8.self)
            case UInt8(ascii: "\\"):
                return nil
            default:
                i += 1
            }
        }
        return nil
    }

    static func newline(in data: Data, from index: Data.Index) -> Data.Index? {
        guard index >= data.startIndex, index < data.endIndex else { return nil }
        return data.withUnsafeBytes { raw -> Data.Index? in
            let offset = index - data.startIndex
            guard let base = raw.baseAddress, let hit = memchr(base + offset, 0x0A, raw.count - offset) else { return nil }
            return data.startIndex + base.distance(to: UnsafeRawPointer(hit))
        }
    }

    /// Calls `body` with each newline-terminated line (newline excluded) until
    /// it returns false; returns the index after the last line visited.
    @discardableResult
    static func forEachLine(in data: Data, _ body: (Data) -> Bool) -> Data.Index {
        var start = data.startIndex
        while let newline = newline(in: data, from: start) {
            let more = body(data[start..<newline])
            start = newline + 1
            if !more { break }
        }
        return start
    }

    /// `count` bytes at `position` (fewer at end of file); nil on a read error.
    static func read(_ fd: Int32, at position: Int64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var filled = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while filled < count {
                let n = pread(fd, base + filled, count - filled, off_t(position) + off_t(filled))
                if n > 0 {
                    filled += n
                } else if n == 0 {
                    break
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
        guard ok else { return nil }
        if filled < count { data.count = filled }
        return data
    }
}
