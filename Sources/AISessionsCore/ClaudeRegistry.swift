import Foundation

/// One `<configDir>/sessions/<pid>.json` record. Every live Claude process
/// keeps one, but a crash leaves it behind, so a record alone proves nothing:
/// see `ClaudeRegistry.isLive`.
public struct ClaudeRegistryRecord: Decodable, Equatable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String?
    /// Epoch milliseconds.
    public var startedAt: Double?
    /// C `asctime` layout in UTC, e.g. "Thu Oct  1 02:59:07 2026".
    public var procStart: String?
    public var kind: String?
    public var entrypoint: String?
    public var name: String?
    public var status: String?
    /// Epoch milliseconds of the last write. It does not heartbeat.
    public var updatedAt: Double?
    /// Epoch milliseconds of the last status transition.
    public var statusUpdatedAt: Double?

    public init(
        pid: Int32,
        sessionId: String,
        cwd: String? = nil,
        startedAt: Double? = nil,
        procStart: String? = nil,
        kind: String? = nil,
        entrypoint: String? = nil,
        name: String? = nil,
        status: String? = nil,
        updatedAt: Double? = nil,
        statusUpdatedAt: Double? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
        self.kind = kind
        self.entrypoint = entrypoint
        self.name = name
        self.status = status
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, procStart, kind, entrypoint, name, status,
             updatedAt, statusUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        // Lenient on purpose: one field changing type in a future Claude
        // release must not hide the whole session.
        cwd = Self.optional(c, .cwd)
        startedAt = Self.optional(c, .startedAt)
        procStart = Self.optional(c, .procStart)
        kind = Self.optional(c, .kind)
        entrypoint = Self.optional(c, .entrypoint)
        name = Self.optional(c, .name)
        status = Self.optional(c, .status)
        updatedAt = Self.optional(c, .updatedAt)
        statusUpdatedAt = Self.optional(c, .statusUpdatedAt)
    }

    private static func optional<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> T? {
        try? c.decodeIfPresent(T.self, forKey: key)
    }

    /// When the current status was entered.
    public var stateSince: Date? {
        ClaudeRegistry.date(millis: statusUpdatedAt ?? updatedAt ?? startedAt)
    }

    /// The newest timestamp in the record, to pick between two records of one session.
    var lastWrite: Double {
        max(updatedAt ?? 0, statusUpdatedAt ?? 0, startedAt ?? 0)
    }
}

/// Reading and validating the live-session registry.
public enum ClaudeRegistry {
    /// Without `procStart`, a record is trusted when its process started at
    /// most this long before the record's `startedAt`.
    static let startedAtWindow: TimeInterval = 120
    /// Clock and rounding slack on the other side of that window.
    static let startedAtSlack: TimeInterval = 2

    /// The registry files in `sessionsDir`: only `<digits>.json`, sorted by pid.
    /// The sibling `<pid>.<hash>.key` files hold secrets: they are filtered
    /// out by name here, so nothing downstream ever opens them.
    public static func records(in sessionsDir: URL) -> [URL] {
        (try? listRecords(in: sessionsDir)) ?? []
    }

    /// `records(in:)`, throwing so the source can tell "no registry yet" from
    /// "not allowed to read it".
    static func listRecords(in sessionsDir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
            .compactMap { name in pid(fromRecordName: name).map { (pid: $0, name: name) } }
            .sorted { $0.pid < $1.pid }
            .map { sessionsDir.appending(component: $0.name, directoryHint: .notDirectory) }
    }

    /// "48433.json" → 48433; every other name → nil.
    static func pid(fromRecordName name: String) -> Int32? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.utf8.dropLast(5)
        guard !stem.isEmpty, stem.count <= 10, stem.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        guard let pid = Int32(String(decoding: stem, as: UTF8.self)), pid > 0 else { return nil }
        return pid
    }

    /// nil for anything but a complete, plausible record — notably a file
    /// caught half-written.
    public static func parse(_ data: Data) -> ClaudeRegistryRecord? {
        guard let record = try? JSONDecoder().decode(ClaudeRegistryRecord.self, from: data),
              record.pid > 0, isValidSessionId(record.sessionId) else { return nil }
        return record
    }

    /// Session ids become file names (`<id>.jsonl`): refuse anything that
    /// could point outside the projects directory.
    static func isValidSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    /// The record's process exists and is the one that wrote it. A crash
    /// leaves the file behind, and its pid may later belong to anything.
    public static func isLive(_ r: ClaudeRegistryRecord) -> Bool {
        ProcessKit.isAlive(r.pid) && startMatches(r) == true
    }

    /// Whether the process now holding `r.pid` started when the record says.
    /// nil when the process cannot be inspected (it just exited): no verdict.
    static func startMatches(_ r: ClaudeRegistryRecord) -> Bool? {
        guard let info = ProcessKit.info(r.pid) else { return nil }
        if let procStart = r.procStart, !procStart.isEmpty {
            return ProcessKit.matchesProcStart(r.pid, procStart: procStart)
        }
        guard let startedAt = r.startedAt else { return true }
        let delay = startedAt / 1000 - info.startTime.timeIntervalSince1970
        return delay >= -startedAtSlack && delay <= startedAtWindow
    }

    /// The extension's own mapping: busy → running, waiting → waiting,
    /// anything else (including future values) → idle.
    public static func activityState(status: String?) -> ActivityState {
        switch status {
        case "busy": return .running
        case "waiting": return .waiting
        default: return .idle
        }
    }

    /// Mirrors the extension's classification: a `kind` other than
    /// "interactive" is automation; otherwise only the terminal, VS Code and
    /// desktop entrypoints are people. `claude -p` (sdk-cli), the SDKs, MCP,
    /// local agents and CI runs are not.
    public static func isInteractive(kind: String?, entrypoint: String?) -> Bool {
        if let kind, !kind.isEmpty, kind != "interactive" { return false }
        switch entrypoint {
        case "cli", "claude-vscode", "claude-desktop", "claude-desktop-3p": return true
        default: return false
        }
    }

    public static func host(for r: ClaudeRegistryRecord) -> SessionHost {
        switch r.entrypoint {
        case "claude-vscode":
            // The parent is the window's extension host. A parent of launchd
            // means it died and the process was reparented: unknown.
            let parent = ProcessKit.info(r.pid)?.ppid
            return .vscode(extensionHostPid: parent.flatMap { $0 > 1 ? $0 : nil })
        case "cli":
            return .terminal(appPid: terminalAppPid(ancestors: ProcessKit.ancestors(of: r.pid),
                                                    path: ProcessKit.path))
        default:
            return .unknown
        }
    }

    /// The nearest ancestor whose executable lives in a `.app` bundle. When
    /// that ancestor is a helper nested in another app (VS Code's integrated
    /// terminal runs under ".../Code.app/Contents/Frameworks/Code Helper.app"),
    /// the app's own process further up is preferred: a helper is not
    /// something that can be activated.
    static func terminalAppPid(ancestors: [ProcInfo], path: (Int32) -> String?) -> Int32? {
        for (index, process) in ancestors.enumerated() {
            guard let executable = path(process.pid),
                  let bundle = ProcessKit.appBundlePath(forExecutable: executable) else { continue }
            let mainExecutables = bundle + "/Contents/MacOS/"
            if executable.hasPrefix(mainExecutables) { return process.pid }
            let app = ancestors[(index + 1)...].first { path($0.pid)?.hasPrefix(mainExecutables) == true }
            return app?.pid ?? process.pid
        }
        return nil
    }

    static func date(millis: Double?) -> Date? {
        millis.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
