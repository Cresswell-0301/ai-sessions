import Foundation

/// How to bring the user back to a session. The executor opens `url` when
/// there is one; the activate fields name the app to bring forward when there
/// is no URL or opening it fails.
public struct RoutePlan: Equatable, Sendable {
    public var url: URL?
    public var activatePid: Int32?
    public var activateBundleIdentifier: String?
    /// One line for the log and `--route`: what this plan does.
    public var summary: String

    public init(url: URL? = nil, activatePid: Int32? = nil, activateBundleIdentifier: String? = nil, summary: String) {
        self.url = url
        self.activatePid = activatePid
        self.activateBundleIdentifier = activateBundleIdentifier
        self.summary = summary
    }

    /// Nothing to open or activate.
    public var isEmpty: Bool { url == nil && activatePid == nil && activateBundleIdentifier == nil }
}

/// Builds the `RoutePlan` for a session: a deep link into the editor window
/// that owns it, or the terminal app to activate.
public enum Router {
    /// Resolves the editor family and window with process and log lookups,
    /// then plans. Costs a few milliseconds; call it on demand, not per poll.
    public static func plan(for session: TrackedSession) -> RoutePlan {
        plan(for: session, lookup: Lookup())
    }

    /// Where the lookups look; tests point them at fixtures.
    struct Lookup {
        var logsRoot: URL?
        var codexExecutableName = "codex"
    }

    static func plan(for session: TrackedSession, lookup: Lookup) -> RoutePlan {
        guard opensInEditor(session) else {
            return plan(for: session, family: .vscode, windowId: nil, liveWindows: 0)
        }
        var hostPid = extensionHostPid(of: session)
        var family = hostPid.flatMap(ProcessKit.path).map(EditorFamily.forAppBundle) ?? .vscode
        switch session.key.agent {
        case .claude:
            let windowId = hostPid.flatMap {
                VSCodeWindowIndex.windowId(forExtensionHostPid: $0, family: family, logsRoot: lookup.logsRoot)
            }
            return plan(for: session, family: family, windowId: windowId, liveWindows: 0)
        case .codex:
            var live = VSCodeWindowIndex.liveWindowCount(family: family, logsRoot: lookup.logsRoot)
            // One live window needs no window id. None suggests the thread is in
            // another family's editor; several need the scan to pick one.
            if hostPid == nil, live != 1, isCodexThreadId(session.key.id),
               let found = VSCodeWindowIndex.codexExtensionHostPid(
                   threadId: session.key.id, executableName: lookup.codexExecutableName) {
                hostPid = found
                let foundFamily = ProcessKit.path(found).map(EditorFamily.forAppBundle) ?? family
                if foundFamily != family {
                    family = foundFamily
                    live = VSCodeWindowIndex.liveWindowCount(family: family, logsRoot: lookup.logsRoot)
                }
            }
            let windowId = live > 1 ? hostPid.flatMap {
                VSCodeWindowIndex.windowId(forExtensionHostPid: $0, family: family, logsRoot: lookup.logsRoot)
            } : nil
            return plan(for: session, family: family, windowId: windowId, liveWindows: live)
        }
    }

    /// Pure planning from already-resolved facts. `liveWindows` only matters
    /// for Codex, whose link carries the window id only when there is a choice.
    public static func plan(for session: TrackedSession, family: EditorFamily, windowId: Int?, liveWindows: Int) -> RoutePlan {
        let agent = session.key.agent
        if opensInEditor(session) {
            let window = windowId.flatMap { $0 > 0 ? $0 : nil }
            let url: URL?
            let linkWindow: Int?
            switch agent {
            case .claude:
                linkWindow = window
                url = claudeDeepLink(sessionId: session.key.id, windowId: linkWindow, scheme: family.urlScheme)
            case .codex:
                linkWindow = liveWindows > 1 ? window : nil
                url = codexDeepLink(threadId: session.key.id, windowId: linkWindow, scheme: family.urlScheme)
            }
            let what = agent == .claude ? "Claude session" : "Codex thread"
            let summary: String
            if url != nil {
                let place = linkWindow.map { "\(family.appName) window \($0)" } ?? "\(family.appName) (last active window)"
                summary = "Open \(what) in \(place)"
            } else if family.bundleIdentifier != nil {
                summary = "Activate \(family.appName): \(what) id \"\(session.key.id)\" cannot be deep-linked"
            } else {
                summary = "Nothing to route to: \(what) id \"\(session.key.id)\" cannot be deep-linked"
            }
            return RoutePlan(url: url, activateBundleIdentifier: family.bundleIdentifier, summary: summary)
        }
        switch session.host {
        case .terminal(let appPid?):
            return RoutePlan(activatePid: appPid, summary: "Activate the terminal app (pid \(appPid))")
        case .terminal(nil):
            return RoutePlan(summary: "Nothing to route to: the terminal app is unknown")
        case .vscode, .unknown:
            if suggestsVSCode(session.entrypoint), let bundle = family.bundleIdentifier {
                return RoutePlan(activateBundleIdentifier: bundle,
                                 summary: "Activate \(family.appName): the session's window is unknown")
            }
            return RoutePlan(summary: "Nothing to route to: the session's host is unknown")
        }
    }

    /// `<scheme>://anthropic.claude-code/open?session=<uuid>[&windowId=<n>]`;
    /// nil unless `sessionId` is a UUID (the extension rejects anything else).
    public static func claudeDeepLink(sessionId: String, windowId: Int?, scheme: String) -> URL? {
        guard UUID(uuidString: sessionId) != nil else { return nil }
        var query = [URLQueryItem(name: "session", value: sessionId)]
        if let windowId, windowId > 0 {
            query.append(URLQueryItem(name: "windowId", value: String(windowId)))
        }
        return deepLink(scheme: scheme, host: "anthropic.claude-code", path: "/open", query: query)
    }

    /// `<scheme>://openai.chatgpt/local/<threadId>[?windowId=<n>]`; nil unless
    /// `threadId` is UUID-like (lowercase hex and dashes, 8–64 characters).
    public static func codexDeepLink(threadId: String, windowId: Int?, scheme: String) -> URL? {
        guard isCodexThreadId(threadId) else { return nil }
        var query: [URLQueryItem] = []
        if let windowId, windowId > 0 {
            query.append(URLQueryItem(name: "windowId", value: String(windowId)))
        }
        return deepLink(scheme: scheme, host: "openai.chatgpt", path: "/local/\(threadId)", query: query)
    }

    // MARK: Helpers

    /// Claude needs a known editor host; a Codex thread started by the VS Code
    /// extension opens there even when its app-server was not located.
    static func opensInEditor(_ session: TrackedSession) -> Bool {
        if case .vscode = session.host { return true }
        return session.key.agent == .codex && (session.entrypoint?.hasPrefix("codex_vscode") ?? false)
    }

    static func suggestsVSCode(_ entrypoint: String?) -> Bool {
        entrypoint?.lowercased().contains("vscode") ?? false
    }

    static func isCodexThreadId(_ id: String) -> Bool {
        (8...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) || byte == UInt8(ascii: "-")
        }
    }

    /// The live extension host of a VS Code session: the one the source
    /// reported, else the parent of the agent's own process.
    private static func extensionHostPid(of session: TrackedSession) -> Int32? {
        if case .vscode(let pid?) = session.host, ProcessKit.isAlive(pid) { return pid }
        guard case .vscode = session.host,
              let agentPid = session.pid,
              let parent = ProcessKit.info(agentPid)?.ppid, parent > 1,
              let exe = ProcessKit.path(parent), exe.contains(".app/") else { return nil }
        return parent
    }

    private static func deepLink(scheme: String, host: String, path: String, query: [URLQueryItem]) -> URL? {
        // URLComponents raises on an invalid scheme rather than returning nil.
        guard let first = scheme.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first),
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }
}
