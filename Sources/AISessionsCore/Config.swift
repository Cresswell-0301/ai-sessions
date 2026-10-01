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

    /// Loads the config, then applies environment overrides (used by tests):
    /// AI_SESSIONS_CLAUDE_DIRS / AI_SESSIONS_CODEX_HOMES (colon-separated).
    public static func load(home: URL = AppPaths.home,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Config {
        var config = Config()
        let url = home.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(Config.self, from: data) {
                config = decoded
            } else {
                Log.shared.warn("config.json is not valid JSON; using defaults")
            }
        }
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
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai-sessions")
    }

    public static var stateDir: URL { home.appendingPathComponent("state") }

    /// Expands a leading `~` and standardizes the path.
    public static func expand(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
