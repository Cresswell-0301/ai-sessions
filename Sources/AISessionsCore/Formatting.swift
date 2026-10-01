import Foundation

/// Human formatting shared by the menu and the notifications.
public enum Formatting {
    /// "8s", "4m", "1h 05m", "3d".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : String(format: "%dh %02dm", h, m % 60) }
        return "\(h / 24)d"
    }

    /// "just now", "4m ago", "2h ago".
    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        return duration(seconds) + " ago"
    }

    /// Collapses whitespace and truncates with an ellipsis.
    public static func oneLine(_ text: String?, max: Int) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= max { return collapsed }
        return String(collapsed.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Project label for a working directory: the last path component, with
    /// Claude/agent worktrees shown as "<repo>/<worktree>".
    public static func project(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let parts = cwd.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: "worktrees"), i >= 2, i + 1 < parts.count {
            // …/<repo>/.claude/worktrees/<name>
            let repo = parts[i - 1].hasPrefix(".") ? parts[i - 2] : parts[i - 1]
            return "\(repo)/\(parts[i + 1])"
        }
        return parts.last ?? cwd
    }
}
