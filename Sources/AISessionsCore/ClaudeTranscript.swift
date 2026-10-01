import Darwin
import Foundation

/// What a session's transcript says about it. The newest entry of each kind wins.
public struct TranscriptInfo: Equatable, Sendable {
    /// The user's rename: what VS Code shows as the tab label.
    public var customTitle: String?
    public var aiTitle: String?
    public var lastPrompt: String?
    /// The newest assistant entry that has any text, its text blocks joined.
    public var lastAssistantText: String?

    public init(customTitle: String? = nil, aiTitle: String? = nil,
                lastPrompt: String? = nil, lastAssistantText: String? = nil) {
        self.customTitle = customTitle
        self.aiTitle = aiTitle
        self.lastPrompt = lastPrompt
        self.lastAssistantText = lastAssistantText
    }
}

/// Locating and reading `<configDir>/projects/<encoded cwd>/<sessionId>.jsonl`.
/// Transcripts pass 100 MB, so reads are bounded: the last 256 KB, plus older
/// chunks (up to 4 MB) only while no title has been found. Claude re-appends
/// its title entries throughout a session, so the tail nearly always has them.
public enum ClaudeTranscript {
    public static let tailBytes = 256 * 1024
    public static let titleScanLimit = 4 * 1024 * 1024
    static let maxTitleLength = 200
    /// Previews only: a pasted log or a long answer is not worth keeping whole.
    static let maxTextLength = 2_000
    /// Claude truncates and hashes longer directory names; those are globbed.
    static let maxProjectNameLength = 200

    // MARK: Locating

    /// Claude's directory name for a project path: every UTF-16 unit that is
    /// not an ASCII letter or digit becomes "-" (as JavaScript's replace does).
    /// nil when Claude would have truncated and hashed it.
    public static func projectDirectoryName(for path: String) -> String? {
        let units = path.utf16
        guard !units.isEmpty, units.count <= maxProjectNameLength else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(units.count)
        for unit in units {
            bytes.append(unit < 0x80 && isASCIIAlphanumeric(UInt8(unit)) ? UInt8(unit) : 0x2D)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `<configDir>/projects/*/<sessionId>.jsonl`, trying the encoded cwd first.
    public static func locate(sessionId: String, configDir: URL, cwd: String?) -> URL? {
        directCandidates(sessionId: sessionId, configDir: configDir, cwd: cwd).first(where: isRegularFile)
            ?? glob(sessionId: sessionId, configDir: configDir)
    }

    /// Where the transcript is when the project name was not hashed: the
    /// encoding uses `realpath(cwd)`, and the raw cwd is a cheap second guess.
    static func directCandidates(sessionId: String, configDir: URL, cwd: String?) -> [URL] {
        guard let cwd, !cwd.isEmpty else { return [] }
        var paths: [String] = []
        if let real = realPath(cwd) { paths.append(real) }
        if !paths.contains(cwd) { paths.append(cwd) }
        return paths.compactMap(projectDirectoryName).map {
            transcriptURL(configDir: configDir, projectDirectory: $0, sessionId: sessionId)
        }
    }

    /// Every project directory, newest match wins.
    static func glob(sessionId: String, configDir: URL) -> URL? {
        let projects = configDir.appending(component: "projects", directoryHint: .isDirectory)
        guard let directories = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        var best: (url: URL, stamp: ClaudeFileStamp)?
        for directory in directories where !directory.hasPrefix(".") {
            let url = transcriptURL(configDir: configDir, projectDirectory: directory, sessionId: sessionId)
            guard let stamp = try? ClaudeFileStamp(path: url.path), stamp.isRegularFile else { continue }
            if best.map({ stamp.isNewer(than: $0.stamp) }) ?? true { best = (url, stamp) }
        }
        return best?.url
    }

    static func transcriptURL(configDir: URL, projectDirectory: String, sessionId: String) -> URL {
        configDir
            .appending(component: "projects", directoryHint: .isDirectory)
            .appending(component: projectDirectory, directoryHint: .isDirectory)
            .appending(component: sessionId + ".jsonl", directoryHint: .notDirectory)
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? ClaudeFileStamp(path: url.path))?.isRegularFile == true
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Reading

    /// The newest entry of each kind within the last `tailBytes`, nothing older.
    public static func readTail(of url: URL) throws -> TranscriptInfo {
        try ClaudeFileIO.withFile(url.path) { fd in
            let stamp = try ClaudeFileStamp(fd: fd)
            var scan = ClaudeTranscriptScan()
            try self.scan(fd: fd, size: stamp.size, limit: tailBytes, into: &scan)
            return scan.info
        }
    }

    /// `readTail(of:)`, plus older chunks when the tail holds no title.
    public static func read(_ url: URL) throws -> TranscriptInfo {
        try ClaudeFileIO.withFile(url.path) { fd in
            let stamp = try ClaudeFileStamp(fd: fd)
            var info = TranscriptInfo()
            try update(&info, fd: fd, size: stamp.size, allowTitleScan: true)
            return info
        }
    }

    /// Folds the tail into `known`: each kind found there replaces the known
    /// value, the others keep it, so a title survives scrolling out of the
    /// tail. Then, if `allowTitleScan` and still no title is known, scans older
    /// chunks for one. Returns whether that scan ran.
    @discardableResult
    static func update(_ known: inout TranscriptInfo, fd: Int32, size: Int64, allowTitleScan: Bool) throws -> Bool {
        var tail = ClaudeTranscriptScan()
        try scan(fd: fd, size: size, limit: tailBytes, into: &tail)
        tail.apply(to: &known)
        guard allowTitleScan, known.customTitle == nil, known.aiTitle == nil else { return false }
        let titles: Set<ClaudeTranscriptScan.Kind> = [.customTitle, .aiTitle]
        var older = ClaudeTranscriptScan(wanted: titles.subtracting(tail.settled))
        try scan(fd: fd, size: size, limit: titleScanLimit, into: &older)
        older.apply(to: &known)
        return true
    }

    /// Feeds the complete lines of the last `limit` bytes to `scan`,
    /// newest first, reading backwards in `chunkSize` pieces and stopping as
    /// soon as the scan has everything it wants.
    static func scan(fd: Int32, size: Int64, limit: Int, chunkSize: Int = tailBytes,
                     into scan: inout ClaudeTranscriptScan) throws {
        let floor = max(0, size - Int64(limit))
        var end = size
        // The start of the line cut by the previous (later) chunk's first byte.
        var carry: [UInt8] = []
        while end > floor, !scan.isComplete {
            let start = max(floor, end - Int64(chunkSize))
            let count = Int(end - start)
            var bytes = try ClaudeFileIO.read(fd, offset: start, count: count)
            // Shrunk under us (rewritten): the caller re-reads on the next change.
            guard bytes.count == count else { return }
            bytes.append(contentsOf: carry)
            carry = bytes.withUnsafeBytes { buffer -> [UInt8] in
                var from = 0
                var held: [UInt8] = []
                if start > 0 {
                    // The first line may have begun before `start`: hold it back
                    // to complete it with the earlier chunk (or drop it at the limit).
                    guard let base = buffer.baseAddress, let newline = memchr(base, 0x0A, buffer.count) else {
                        return Array(buffer)
                    }
                    let index = base.distance(to: UnsafeRawPointer(newline))
                    held = Array(buffer[..<index])
                    from = index + 1
                }
                feedLines(buffer, from: from, into: &scan)
                return held
            }
            end = start
        }
    }

    /// Hands the lines of `buffer[from...]` to `scan`, last line first. The
    /// final segment may lack its newline (a line being written); it is
    /// offered too, and simply fails to parse if incomplete.
    static func feedLines(_ buffer: UnsafeRawBufferPointer, from: Int, into scan: inout ClaudeTranscriptScan) {
        guard let base = buffer.baseAddress, from < buffer.count else { return }
        var lines: [Range<Int>] = []
        var lineStart = from
        while lineStart < buffer.count {
            guard let newline = memchr(base + lineStart, 0x0A, buffer.count - lineStart) else {
                lines.append(lineStart..<buffer.count)
                break
            }
            let lineEnd = base.distance(to: UnsafeRawPointer(newline))
            if lineEnd > lineStart { lines.append(lineStart..<lineEnd) }
            lineStart = lineEnd + 1
        }
        for line in lines.reversed() {
            scan.consider(UnsafeRawBufferPointer(rebasing: buffer[line]))
            if scan.isComplete { return }
        }
    }

    /// Trimmed and capped; nil when nothing is left.
    static func clean(_ text: String, maxLength: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}

/// One pass over transcript lines, fed newest first: the first entry of each
/// wanted kind settles it.
struct ClaudeTranscriptScan {
    enum Kind: CaseIterable, Hashable {
        case customTitle, aiTitle, lastPrompt, assistantText

        var field: WritableKeyPath<TranscriptInfo, String?> {
            switch self {
            case .customTitle: return \.customTitle
            case .aiTitle: return \.aiTitle
            case .lastPrompt: return \.lastPrompt
            case .assistantText: return \.lastAssistantText
            }
        }
    }

    let wanted: Set<Kind>
    private(set) var settled: Set<Kind> = []
    private(set) var info = TranscriptInfo()

    init(wanted: Set<Kind> = Set(Kind.allCases)) {
        self.wanted = wanted
    }

    var isComplete: Bool { wanted.isSubset(of: settled) }

    /// Copies every settled kind into `known`; unsettled kinds keep their value.
    func apply(to known: inout TranscriptInfo) {
        for kind in settled { known[keyPath: kind.field] = info[keyPath: kind.field] }
    }

    mutating func consider(_ line: UnsafeRawBufferPointer) {
        guard isCandidate(line), let entry = Self.parse(line) else { return }
        switch entry["type"] as? String {
        case "custom-title":
            settle(.customTitle, entry["customTitle"], maxLength: ClaudeTranscript.maxTitleLength)
        case "ai-title":
            settle(.aiTitle, entry["aiTitle"], maxLength: ClaudeTranscript.maxTitleLength)
        case "last-prompt":
            settle(.lastPrompt, entry["lastPrompt"], maxLength: ClaudeTranscript.maxTextLength)
        case "assistant":
            // Sub-agent (sidechain) chatter is not the session's last word.
            guard isPending(.assistantText), entry["isSidechain"] as? Bool != true,
                  let text = Self.assistantText(entry) else { return }
            info.lastAssistantText = ClaudeTranscript.clean(text, maxLength: ClaudeTranscript.maxTextLength)
            settled.insert(.assistantText)
        default:
            break
        }
    }

    private func isPending(_ kind: Kind) -> Bool {
        wanted.contains(kind) && !settled.contains(kind)
    }

    /// A substring test first, so most lines never reach JSONSerialization.
    /// A false positive only costs a parse: the parsed `type` decides.
    private func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        (isPending(.customTitle) && Self.contains(line, "\"custom-title\""))
            || (isPending(.aiTitle) && Self.contains(line, "\"ai-title\""))
            || (isPending(.lastPrompt) && Self.contains(line, "\"last-prompt\""))
            || (isPending(.assistantText) && Self.contains(line, "\"assistant\"") && Self.contains(line, "\"text\""))
    }

    /// An entry without its payload string (older formats write some) does
    /// not settle anything; an empty one does, as "none".
    private mutating func settle(_ kind: Kind, _ value: Any?, maxLength: Int) {
        guard isPending(kind), let text = value as? String else { return }
        info[keyPath: kind.field] = ClaudeTranscript.clean(text, maxLength: maxLength)
        settled.insert(kind)
    }

    static func parse(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress, !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes: base, count: line.count))) as? [String: Any]
    }

    /// The entry's non-blank text blocks joined, or nil if it has none
    /// (a tool call, a thinking block).
    static func assistantText(_ entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [Any] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard let block = block as? [String: Any], block["type"] as? String == "text",
                  let text = block["text"] as? String, text.contains(where: { !$0.isWhitespace }) else { return nil }
            return text
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = haystack.baseAddress else { return false }
        return needle.withUTF8Buffer { pattern in
            guard let patternBase = pattern.baseAddress else { return true }
            return memmem(base, haystack.count, patternBase, pattern.count) != nil
        }
    }
}

/// One session's transcript as `ClaudeSource` follows it: where the file is,
/// which version of it was read last, and what is known so far.
final class ClaudeTranscriptCache {
    /// While the transcript is missing, the full glob of every project
    /// directory runs at most this often (the encoded-cwd guess runs every poll).
    static let globInterval: TimeInterval = 30

    let sessionId: String
    let configDir: URL
    private let directCandidates: [URL]
    private(set) var url: URL?
    private var lastGlob: Date?
    /// The file version `info` reflects.
    private(set) var readStamp: ClaudeFileStamp?
    private(set) var info = TranscriptInfo()
    private var titleScanDone = false
    /// How many backward title scans ran: at most one per file.
    private(set) var titleScanCount = 0

    init(sessionId: String, configDir: URL, cwd: String?) {
        self.sessionId = sessionId
        self.configDir = configDir
        directCandidates = ClaudeTranscript.directCandidates(sessionId: sessionId, configDir: configDir, cwd: cwd)
    }

    /// The transcript's current stamp (one `stat`), locating it first when
    /// it is not known yet or has gone. nil while there is none.
    func currentStamp(now: Date) -> ClaudeFileStamp? {
        if let url {
            if let stamp = try? ClaudeFileStamp(path: url.path), stamp.isRegularFile { return stamp }
            self.url = nil
        }
        guard let found = locate(now: now) else { return nil }
        url = found
        return try? ClaudeFileStamp(path: found.path)
    }

    private func locate(now: Date) -> URL? {
        if let hit = directCandidates.first(where: ClaudeTranscript.isRegularFile) { return hit }
        if let lastGlob {
            let elapsed = now.timeIntervalSince(lastGlob)
            if elapsed >= 0, elapsed < Self.globInterval { return nil }
        }
        lastGlob = now
        return ClaudeTranscript.glob(sessionId: sessionId, configDir: configDir)
    }

    /// Reads the tail of the located file into `info` and, once per file,
    /// older chunks when no title is known.
    func refresh() throws {
        guard let url else { return }
        try ClaudeFileIO.withFile(url.path) { fd in
            let stamp = try ClaudeFileStamp(fd: fd)
            guard stamp.isRegularFile else { throw POSIXError(.EFTYPE) }
            if let previous = readStamp, !previous.isSameFile(as: stamp) || stamp.size < previous.size {
                // Replaced or rewritten: what is known described another file.
                info = TranscriptInfo()
                titleScanDone = false
            }
            if try ClaudeTranscript.update(&info, fd: fd, size: stamp.size, allowTitleScan: !titleScanDone) {
                titleScanDone = true
                titleScanCount += 1
            }
            readStamp = stamp
        }
    }
}

/// A file's identity and version from one `stat`: tells "changed" without reading it.
struct ClaudeFileStamp: Equatable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
    var changedSeconds: Int
    var changedNanoseconds: Int
    var isRegularFile: Bool

    init(path: String) throws {
        var info = stat()
        guard stat(path, &info) == 0 else { throw ClaudeFileIO.lastError() }
        self.init(info)
    }

    init(fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ClaudeFileIO.lastError() }
        self.init(info)
    }

    private init(_ info: stat) {
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
        changedSeconds = Int(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int(info.st_ctimespec.tv_nsec)
        isRegularFile = (info.st_mode & S_IFMT) == S_IFREG
    }

    func isSameFile(as other: ClaudeFileStamp) -> Bool {
        device == other.device && inode == other.inode
    }

    func isNewer(than other: ClaudeFileStamp) -> Bool {
        (modifiedSeconds, modifiedNanoseconds) > (other.modifiedSeconds, other.modifiedNanoseconds)
    }
}

/// Plain POSIX reads with errno-based errors, so callers can tell a file
/// that vanished (normal) from one they may not read (worth one log line).
enum ClaudeFileIO {
    static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// O_NONBLOCK so that a FIFO where a file is expected cannot hang a poll.
    static func withFile<T>(_ path: String, _ body: (Int32) throws -> T) throws -> T {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw lastError() }
        defer { close(fd) }
        return try body(fd)
    }

    /// `count` bytes at `offset`, or fewer if the file is shorter now.
    static func read(_ fd: Int32, offset: Int64, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = bytes.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + done, count - done, offset + Int64(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw lastError()
            }
            if n == 0 { break }
            done += n
        }
        if done < count { bytes.removeLast(count - done) }
        return bytes
    }

    /// A whole small regular file, refusing anything bigger than `limit`.
    static func readSmallFile(_ path: String, limit: Int) throws -> Data {
        try withFile(path) { fd in
            let stamp = try ClaudeFileStamp(fd: fd)
            guard stamp.isRegularFile else { throw POSIXError(.EFTYPE) }
            guard stamp.size <= Int64(limit) else { throw POSIXError(.EFBIG) }
            return Data(try read(fd, offset: 0, count: Int(stamp.size)))
        }
    }

    static func isNotFound(_ error: Error) -> Bool {
        if let posix = error as? POSIXError { return posix.code == .ENOENT || posix.code == .ENOTDIR }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(ENOENT) || underlying.code == Int(ENOTDIR)
        }
        return false
    }

    static func describe(_ error: Error) -> String {
        if let posix = error as? POSIXError { return String(cString: strerror(posix.code.rawValue)) }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return ns.localizedDescription
    }
}
