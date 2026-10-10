import Darwin
import Foundation

/// The Claude accounts the user works on: the email each watched config dir
/// is signed into, as Claude Code records it in that dir's `.claude.json`
/// (`oauthAccount.emailAddress`; the default `~/.claude` keeps the file one
/// level up, in `~/.claude.json`). Only the address is read: the tokens live
/// in the Keychain, never in this file. The ai-accounts dashboard names its
/// accounts by the same address, which is how a dashboard row is matched.
///
/// A file is parsed again only when its stamp changes. One that cannot be
/// read or parsed (Claude Code rewriting it) keeps that dir's last answer,
/// so a write in progress never looks like an account switch.
/// Not thread-safe: the app uses it on the main actor.
public final class SignedInAccounts {
    /// What one config dir says.
    enum Answer: Equatable {
        case signedIn(String)
        /// The file reads fine and names no account (logged out).
        case signedOut
    }

    private struct Stamp: Equatable {
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    public let configDirs: [URL]
    private let home: URL
    private var answers: [URL: Answer] = [:]
    private var stamps: [URL: Stamp] = [:]

    public init(configDirs: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.configDirs = configDirs
        self.home = home
    }

    /// The lower-cased emails signed in now; nil while no watched dir has
    /// given an answer yet (none readable), so the caller can wait rather
    /// than act on a guess.
    public func emails() -> Set<String>? {
        var known = false
        var emails = Set<String>()
        for dir in configDirs {
            guard let answer = answer(for: dir) else { continue }
            known = true
            if case .signedIn(let email) = answer { emails.insert(email) }
        }
        return known ? emails : nil
    }

    /// Where `dir` keeps its account: inside it for a profile
    /// (`CLAUDE_CONFIG_DIR`), `~/.claude.json` for the default `~/.claude`.
    /// The same order as the dashboard's `claude_identity`.
    func candidates(for dir: URL) -> [URL] {
        var files = [dir.appendingPathComponent(".claude.json")]
        let defaultDir = home.appendingPathComponent(".claude")
        if dir.resolvingSymlinksInPath().standardizedFileURL.path
            == defaultDir.resolvingSymlinksInPath().standardizedFileURL.path {
            files.append(home.appendingPathComponent(".claude.json"))
        }
        return files
    }

    private func answer(for dir: URL) -> Answer? {
        var nobody: Answer?
        for file in candidates(for: dir) {
            guard let found = answer(in: file) else { continue }
            // A file that names nobody gives way to a later one that names
            // someone, as in the dashboard's own lookup.
            guard found == .signedOut else { return found }
            nobody = found
        }
        return nobody
    }

    /// What `file` says now; re-read only when its stamp changed. Missing:
    /// nil. Unreadable for a moment (being rewritten): its last answer.
    private func answer(in file: URL) -> Answer? {
        guard let stamp = Stamp(path: file.path) else { return nil }
        if stamps[file] == stamp, let cached = answers[file] { return cached }
        guard let parsed = Self.read(file) else { return answers[file] }
        stamps[file] = stamp
        answers[file] = parsed
        return parsed
    }

    static func read(_ file: URL) -> Answer? {
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let account = root["oauthAccount"] as? [String: Any],
              let email = (account["emailAddress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return .signedOut }
        return .signedIn(email.lowercased())
    }
}
