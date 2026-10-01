import Foundation

// Shared contracts between the session sources, the tracker engine, the
// router and the app. Keep this file stable: every module builds against it.

/// Which coding agent a session belongs to.
public enum Agent: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// Stable identity of a session across polls and app restarts.
public struct SessionKey: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let agent: Agent
    public let id: String

    public init(agent: Agent, id: String) {
        self.agent = agent
        self.id = id
    }

    /// Parses the `description` form, e.g. "claude:9eb4895f-…".
    public init?(string: String) {
        guard let colon = string.firstIndex(of: ":"),
              let agent = Agent(rawValue: String(string[..<colon])) else { return nil }
        let id = String(string[string.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        self.init(agent: agent, id: id)
    }

    public var description: String { "\(agent.rawValue):\(id)" }

    public static func < (lhs: SessionKey, rhs: SessionKey) -> Bool {
        lhs.description < rhs.description
    }
}

/// What the agent in a session is doing right now.
public enum ActivityState: String, Codable, Sendable {
    /// The agent is working on a turn.
    case running
    /// Blocked on the user: a permission prompt, a question, a plan approval.
    case waiting
    /// The turn is over; the session waits for the next prompt.
    case idle
}

/// How a turn came to an end. Only a completed turn is news: the user caused
/// an interrupted one a moment ago, and an abandoned one never produced an
/// answer to look at.
public enum TurnEnd: String, Codable, Sendable {
    /// The agent finished its answer.
    case completed
    /// Stopped before its answer: Esc in Claude, Stop in Codex (or Codex
    /// aborting the turn itself, e.g. when its window reloads).
    case interrupted
    /// It never ended: the process running it died, or it went silent for
    /// hours with no turn end written.
    case abandoned
}

/// Where a session lives, so the router can bring the user back to it.
public enum SessionHost: Codable, Equatable, Sendable {
    /// Inside a VS Code-family editor window. `extensionHostPid` is the
    /// "Code Helper (Plugin)" process that owns the window (the parent of a
    /// Claude process); nil when unknown.
    case vscode(extensionHostPid: Int32?)
    /// A CLI session in a terminal. `appPid` is the nearest ancestor process
    /// that is a GUI app (Terminal, iTerm2, …); nil when unknown.
    case terminal(appPid: Int32?)
    case unknown
}

/// One poll's view of one session, produced by a `SessionSource`.
public struct Observation: Equatable, Sendable {
    public var key: SessionKey
    public var state: ActivityState
    /// The source's raw status string (e.g. Claude registry "busy"/"idle"/"waiting").
    public var rawStatus: String?
    /// When `state` was entered, as reported by the source.
    public var stateSince: Date?
    /// Best human title the source knows (custom tab title > AI title > …).
    public var title: String?
    public var cwd: String?
    /// The agent's own process, when it has one (Claude CLI process).
    public var pid: Int32?
    /// Claude: "claude-vscode", "cli", … ; Codex: originator "codex_vscode", …
    public var entrypoint: String?
    /// Preview of the agent's last message, when cheaply available.
    public var lastMessage: String?
    public var host: SessionHost
    /// False for automation the user did not start interactively
    /// (`claude -p`, SDK runs, `codex exec` probes, sub-agents).
    public var interactive: Bool
    /// When `pid` started, as the source records it (Claude's registry
    /// `procStart`): with the pid, it tells the process that ran a turn from
    /// a later one, even one that reuses the pid.
    public var procStart: String?
    /// How the turn that led to this idle state ended; nil while running or
    /// waiting, or when the source cannot tell (then it counts as completed).
    public var turnEnd: TurnEnd?

    public init(
        key: SessionKey,
        state: ActivityState,
        rawStatus: String? = nil,
        stateSince: Date? = nil,
        title: String? = nil,
        cwd: String? = nil,
        pid: Int32? = nil,
        entrypoint: String? = nil,
        lastMessage: String? = nil,
        host: SessionHost = .unknown,
        interactive: Bool = true,
        procStart: String? = nil,
        turnEnd: TurnEnd? = nil
    ) {
        self.key = key
        self.state = state
        self.rawStatus = rawStatus
        self.stateSince = stateSince
        self.title = title
        self.cwd = cwd
        self.pid = pid
        self.entrypoint = entrypoint
        self.lastMessage = lastMessage
        self.host = host
        self.interactive = interactive
        self.procStart = procStart
        self.turnEnd = turnEnd
    }
}

/// A provider of session observations (Claude registry, Codex rollouts, …).
/// `poll` is called on one serial queue, about once per second, so
/// implementations must cache and re-read only what changed.
public protocol SessionSource: AnyObject {
    var agent: Agent { get }
    /// Every session this source currently considers alive or recently active.
    /// A session missing from the result is treated as ended.
    func poll(now: Date) -> [Observation]
}

/// The tracker's merged, display-ready view of a session.
public struct TrackedSession: Equatable, Codable, Sendable {
    public var key: SessionKey
    public var title: String
    /// Short project label, normally the last path component of `cwd`.
    public var project: String
    public var cwd: String?
    public var state: ActivityState
    public var rawStatus: String?
    public var stateSince: Date?
    /// When the current (or most recent) running period began.
    public var turnStartedAt: Date?
    /// Length of the most recently completed turn.
    public var lastTurnDuration: TimeInterval?
    /// How the turn `lastTurnDuration` measures came to an end; nil when
    /// unknown. An interrupted or abandoned turn is never announced.
    public var lastTurnEnd: TurnEnd?
    /// Finished or needs input, and the user has not looked at it yet.
    public var unread: Bool
    public var lastMessage: String?
    public var pid: Int32?
    public var entrypoint: String?
    public var host: SessionHost
    public var interactive: Bool
    public var firstSeen: Date
    /// Last time `state` or `unread` changed.
    public var lastChange: Date

    public init(
        key: SessionKey,
        title: String,
        project: String,
        cwd: String? = nil,
        state: ActivityState,
        rawStatus: String? = nil,
        stateSince: Date? = nil,
        turnStartedAt: Date? = nil,
        lastTurnDuration: TimeInterval? = nil,
        unread: Bool = false,
        lastMessage: String? = nil,
        pid: Int32? = nil,
        entrypoint: String? = nil,
        host: SessionHost = .unknown,
        interactive: Bool = true,
        firstSeen: Date,
        lastChange: Date,
        lastTurnEnd: TurnEnd? = nil
    ) {
        self.key = key
        self.title = title
        self.project = project
        self.cwd = cwd
        self.state = state
        self.rawStatus = rawStatus
        self.stateSince = stateSince
        self.turnStartedAt = turnStartedAt
        self.lastTurnDuration = lastTurnDuration
        self.lastTurnEnd = lastTurnEnd
        self.unread = unread
        self.lastMessage = lastMessage
        self.pid = pid
        self.entrypoint = entrypoint
        self.host = host
        self.interactive = interactive
        self.firstSeen = firstSeen
        self.lastChange = lastChange
    }

    /// The session needs the user: waiting on input, or finished and unread.
    public var needsAttention: Bool { state == .waiting || unread }
}

/// What the tracker tells the app after each tick.
public enum TrackerEvent: Equatable, Sendable {
    /// running -> idle, the turn completed (an interrupted or abandoned one
    /// emits nothing). The app notifies when the turn was long enough.
    case finished(TrackedSession)
    /// any -> waiting. The app always notifies.
    case needsInput(TrackedSession)
    /// -> running again: any delivered notification for it is stale.
    case resumed(SessionKey)
    /// The session disappeared (process exited / thread went quiet).
    case ended(SessionKey)
}
