import Darwin
import Foundation

/// User settings, read from `<home>/config.json`. Every key is optional;
/// missing keys keep their defaults, unknown keys are ignored.
public struct Config: Codable, Equatable, Sendable {
    /// Post macOS notifications at all.
    public var notificationsEnabled: Bool = true
    /// Play the default sound with each notification.
    public var sound: Bool = true
    /// A finished turn shorter than this is not announced (and not marked
    /// unread): you were probably watching it. Needs-input is always announced.
    public var minTurnSecondsToNotify: Double = 10
    /// Claude config homes to watch (each has a `sessions/` registry).
    public var claudeConfigDirs: [String] = ["~/.claude"]
    /// Codex homes to watch (each has `sessions/YYYY/MM/DD/rollout-*.jsonl`).
    /// ~/.ai-accounts/codex/* is deliberately absent: those are `codex exec` probes.
    public var codexHomes: [String] = ["~/.codex"]
    /// A Codex thread stays listed this long after its last activity.
    public var codexRecentHours: Double = 12
    /// List `claude -p` / SDK / `codex exec` / sub-agent sessions too.
    public var showAutomationSessions: Bool = false
    public var pollIntervalSeconds: Double = 1.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case notificationsEnabled, sound, minTurnSecondsToNotify, claudeConfigDirs,
             codexHomes, codexRecentHours, showAutomationSessions, pollIntervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
        sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? d.sound
        minTurnSecondsToNotify = (try? c.decodeIfPresent(Double.self, forKey: .minTurnSecondsToNotify)) ?? d.minTurnSecondsToNotify
        claudeConfigDirs = (try? c.decodeIfPresent([String].self, forKey: .claudeConfigDirs)) ?? d.claudeConfigDirs
        codexHomes = (try? c.decodeIfPresent([String].self, forKey: .codexHomes)) ?? d.codexHomes
        codexRecentHours = (try? c.decodeIfPresent(Double.self, forKey: .codexRecentHours)) ?? d.codexRecentHours
        showAutomationSessions = (try? c.decodeIfPresent(Bool.self, forKey: .showAutomationSessions)) ?? d.showAutomationSessions
        pollIntervalSeconds = (try? c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds)) ?? d.pollIntervalSeconds
    }

    /// The settings a process starts with (see `launch`).
    public static func load(home: URL = AppPaths.home,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Config {
        launch(home: home, environment: environment).config
    }

    /// The settings a process starts with: config.json when it decodes, the
    /// defaults when there is none. A broken file (a comment, a half-typed
    /// value, an unclosed brace) is logged and falls back to the last good
    /// copy, else to the defaults: a typo must not silently turn back on the
    /// notifications and sound the user turned off. Environment overrides
    /// apply on top (see `overridden(by:)`).
    public static func launch(home: URL = AppPaths.home,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> Launch {
        let file = read(home: home)
        switch file {
        case .missing:
            return Launch(config: Config().overridden(by: environment), file: file, usedLastGood: false)
        case .valid(let config, _):
            return Launch(config: config.overridden(by: environment), file: file, usedLastGood: false)
        case .invalid(let reason):
            let kept = lastGood(home: home)
            Log.shared.warn("config.json has an error (\(reason)); using "
                + (kept == nil ? "the defaults" : "the last settings that worked (state/\(lastGoodName))"))
            return Launch(config: (kept ?? Config()).overridden(by: environment), file: file,
                          usedLastGood: kept != nil)
        }
    }

    /// What `launch` found and settled on.
    public struct Launch: Equatable, Sendable {
        public var config: Config
        public var file: File
        /// For a broken file: the last good copy stood in (else the defaults).
        public var usedLastGood: Bool
    }

    /// What `<home>/config.json` holds right now.
    public enum File: Equatable, Sendable {
        /// No file: every setting has its default.
        case missing
        /// It decoded. `data` is the file as read, for the last good copy.
        case valid(Config, data: Data)
        /// It is there but unreadable, not JSON, or not a JSON object.
        case invalid(reason: String)
    }

    /// Reads config.json as it is, without any fallback.
    public static func read(home: URL = AppPaths.home) -> File {
        let data: Data
        do {
            data = try Data(contentsOf: home.appendingPathComponent("config.json"))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
        do {
            return .valid(try JSONDecoder().decode(Config.self, from: data), data: data)
        } catch {
            return .invalid(reason: describe(error))
        }
    }

    /// "not valid JSON: Unexpected character '/' around line 1, column 1."
    private static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case .dataCorrupted(let context)?:
            let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return "not valid JSON" + (detail.map { ": " + $0 } ?? "")
        case .typeMismatch?, .valueNotFound?:
            return "not a JSON object"
        default:
            return error.localizedDescription
        }
    }

    // MARK: Last good copy

    static let lastGoodName = "config.last-good.json"

    /// The last config.json that decoded, kept in `state/` by the app.
    public static func lastGoodURL(home: URL = AppPaths.home) -> URL {
        home.appendingPathComponent("state").appendingPathComponent(lastGoodName)
    }

    public static func lastGood(home: URL = AppPaths.home) -> Config? {
        guard let data = try? Data(contentsOf: lastGoodURL(home: home)) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    /// Keeps `data`, a config.json that decoded, as the last good copy. No
    /// write when the copy already holds it, so a launch costs none.
    public static func rememberLastGood(_ data: Data, home: URL = AppPaths.home) {
        let url = lastGoodURL(home: home)
        guard (try? Data(contentsOf: url)) != data else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.shared.warn("could not keep a copy of config.json in \(url.path): \(error.localizedDescription)")
        }
    }

    /// Without config.json the settings that work are the defaults; a later
    /// broken file must not bring back what was there before the deletion.
    public static func forgetLastGood(home: URL = AppPaths.home) {
        try? FileManager.default.removeItem(at: lastGoodURL(home: home))
    }

    // MARK: Overrides

    /// Environment overrides (used by tests): AI_SESSIONS_CLAUDE_DIRS /
    /// AI_SESSIONS_CODEX_HOMES (colon-separated). The poll interval is then
    /// held to 0.25–10 s.
    public func overridden(by environment: [String: String]) -> Config {
        var config = self
        if let dirs = environment["AI_SESSIONS_CLAUDE_DIRS"] {
            config.claudeConfigDirs = dirs.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        if let homes = environment["AI_SESSIONS_CODEX_HOMES"] {
            config.codexHomes = homes.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        config.pollIntervalSeconds = min(max(config.pollIntervalSeconds, 0.25), 10)
        return config
    }

    public var claudeConfigURLs: [URL] { claudeConfigDirs.map(AppPaths.expand) }
    public var codexHomeURLs: [URL] { codexHomes.map(AppPaths.expand) }
}

/// Filesystem locations of the tool itself.
public enum AppPaths {
    /// `~/.ai-sessions`, or `$AI_SESSIONS_HOME` (tests point this at a temp dir).
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["AI_SESSIONS_HOME"], !override.isEmpty {
            return expand(override)
        }
        return defaultHome
    }

    /// The installed app's home, `~/.ai-sessions`.
    public static var defaultHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai-sessions")
    }

    public static var stateDir: URL { home.appendingPathComponent("state") }

    /// Expands a leading `~` and standardizes the path.
    public static func expand(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// Makes `directory` (`state/`) owner-only, as the launch umask (077)
    /// makes everything written there from then on: directories 0700, files
    /// 0600. It holds titles, prompts and last messages copied out of
    /// ~/.claude, which is 0700; older versions, and launchd for launchd.log,
    /// left them world-readable. `create` makes the directory when missing.
    /// Symbolic links are skipped: chmod would follow them out of `state/`.
    public static func secureStateDirectory(_ directory: URL = stateDir, create: Bool) {
        let fm = FileManager.default
        if create {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        restrict(directory.path)
        guard let items = fm.enumerator(atPath: directory.path) else { return }
        for case let item as String in items { restrict(directory.appendingPathComponent(item).path) }
    }

    private static func restrict(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let wanted: mode_t
        switch info.st_mode & S_IFMT {
        case S_IFDIR: wanted = 0o700
        case S_IFREG: wanted = 0o600
        default: return
        }
        if info.st_mode & 0o7777 != wanted { chmod(path, wanted) }
    }
}
