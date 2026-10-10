import Foundation

/// Where usage alerts go on Telegram: the user's own bot (made with
/// @BotFather) and the private chat they opened with it. The token is a
/// secret: it lives only in `state/telegram.json` (0600, in the 0700 state
/// dir), never in config.json, logs or errors.
public struct TelegramSettings: Codable, Equatable, Sendable {
    public var botToken: String
    public var chatId: Int64
    public var botUsername: String?
    /// Who the chat is with, for the menu ("Telegram → Cresswell").
    public var chatName: String?
    /// The chat has been given the "📊 Usage" button (a reply keyboard stays
    /// once sent); a connection made before the button existed gets it once.
    public var keyboardShown: Bool?

    public init(botToken: String, chatId: Int64, botUsername: String? = nil, chatName: String? = nil,
                keyboardShown: Bool? = nil) {
        self.botToken = botToken
        self.chatId = chatId
        self.botUsername = botUsername
        self.chatName = chatName
        self.keyboardShown = keyboardShown
    }

    public static var standardURL: URL { AppPaths.stateDir.appendingPathComponent("telegram.json") }

    public static func load(from url: URL = standardURL) -> TelegramSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TelegramSettings.self, from: data)
    }

    /// Written 0600 from the start (no window where it is world-readable).
    public func save(to url: URL = standardURL) throws {
        try OwnerOnlyFile.write(try JSONEncoder().encode(self), to: url)
    }

    /// Forgets the bot, including a temp copy a crash left mid-save.
    public static func delete(at url: URL = standardURL) {
        try? FileManager.default.removeItem(at: url)
        OwnerOnlyFile.removeLeftovers(of: url)
    }

    /// "@ai_sessions_bot → Cresswell".
    public var summary: String {
        let bot = botUsername.map { "@\($0)" } ?? "your bot"
        return chatName.map { "\(bot) → \($0)" } ?? bot
    }
}

/// Writes files only their owner can read: created 0600 under a temp name
/// in the same 0700 directory, then renamed over the old one, so there is no
/// moment where the file is readable by others or half-written.
public enum OwnerOnlyFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, url.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Temp copies of `url` that a crash between create and rename left.
    public static func removeLeftovers(of url: URL) {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)."
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// What can go wrong talking to Telegram, in words fit for an alert.
/// Never carries the token: request URLs contain it, so they are not kept.
public struct TelegramError: Error, Equatable, LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Telegram was not reached, was busy or asked to slow down: the same
        /// message may go through later.
        case transient
        /// Sending it again cannot help until something changes: a revoked
        /// token, a blocked bot, a rejected message.
        case permanent
    }

    public var message: String
    public var kind: Kind
    /// Telegram's own "retry after N s" (HTTP 429).
    public var retryAfter: TimeInterval?
    /// The HTTP status Telegram answered with; nil when it was not reached.
    public var status: Int?

    public init(_ message: String, kind: Kind = .permanent, retryAfter: TimeInterval? = nil, status: Int? = nil) {
        self.message = message
        self.kind = kind
        self.retryAfter = retryAfter
        self.status = status
    }

    public var errorDescription: String? { message }

    /// Any error from a send, as a TelegramError: the client's own pass
    /// through; anything else (a closure in a test) counts as transient.
    public static func from(_ error: Error) -> TelegramError {
        error as? TelegramError ?? TelegramError(error.localizedDescription, kind: .transient)
    }
}

/// The Telegram Bot API calls this app needs. `transport` is injectable so
/// tests never reach the network.
public struct TelegramClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public struct Bot: Equatable, Sendable {
        public var username: String
        public var name: String
    }

    public struct Chat: Equatable, Sendable {
        public var id: Int64
        public var name: String
        /// The person's own @username, when they have one.
        public var username: String?

        public init(id: Int64, name: String, username: String? = nil) {
            self.id = id
            self.name = name
            self.username = username
        }
    }

    /// Telegram's limit for one message, in UTF-16 units after parsing.
    public static let maxMessageLength = 4096

    /// The button kept under the chat: one tap asks for a usage report.
    public static let usageButtonTitle = "📊 Usage"
    /// What the "📊 Usage now" button under an alert sends back.
    public static let usageCallbackData = "usage"

    public let token: String
    let transport: Transport
    static let base = URL(string: "https://api.telegram.org")!

    public init(token: String, transport: @escaping Transport = TelegramClient.urlSession) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    /// A token from @BotFather looks like "123456789:AA…": digits, a colon,
    /// then 30+ URL-safe characters. Checked before it goes into a URL path.
    public static func looksLikeToken(_ token: String) -> Bool {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }), parts[1].count >= 30 else { return false }
        return parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// A fresh code for one setup: the payload of `t.me/<bot>?start=<code>`.
    /// 10 hex digits (40 bits) — short enough to type, too many to guess
    /// during the minute a setup waits.
    public static func makeStartCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<10).map { _ in String(Int.random(in: 0..<16, using: &generator), radix: 16) }.joined()
    }

    /// The link that opens the bot in Telegram and, on Start, sends it
    /// "/start <code>".
    public static func startLink(bot: String, code: String) -> URL? {
        URL(string: "https://t.me/\(bot)?start=\(code)")
    }

    /// Which bot the token belongs to (and that it works at all).
    public func me() async throws -> Bot {
        let result = try await call("getMe", body: nil)
        guard let bot = result as? [String: Any], let username = bot["username"] as? String else {
            throw TelegramError("Telegram answered getMe without a bot name")
        }
        return Bot(username: username, name: bot["first_name"] as? String ?? username)
    }

    /// The private chat that answered this setup's code: pressed Start on
    /// `startLink(bot:code:)` (Telegram then sends "/start <code>"), or sent
    /// the code itself. Nobody else's message counts, so a stranger who found
    /// the bot cannot claim the alerts. Reads every waiting update, a page
    /// of up to 100 at a time; moving to the next page tells Telegram the
    /// earlier ones were read. nil when the code has not arrived yet.
    /// `allowed_updates` is left alone on purpose: Telegram keeps that filter
    /// for later calls, so setting it would change the bot for anyone else.
    public func chatThatSent(code: String, bot: String, maxPages: Int = 20) async throws -> Chat? {
        var offset: Int64?
        for _ in 0..<maxPages {
            var body: [String: Any] = ["timeout": 0, "limit": 100]
            if let offset { body["offset"] = offset }
            guard let updates = try await call("getUpdates", body: body) as? [Any], !updates.isEmpty else { return nil }
            var newest: Int64?
            for case let update as [String: Any] in updates {
                if let id = (update["update_id"] as? NSNumber)?.int64Value { newest = max(newest ?? id, id) }
                guard let message = update["message"] as? [String: Any],
                      let chat = message["chat"] as? [String: Any], chat["type"] as? String == "private",
                      let id = (chat["id"] as? NSNumber)?.int64Value,
                      let text = message["text"] as? String,
                      Self.answers(text, code: code, bot: bot) else { continue }
                let name = [chat["first_name"] as? String, chat["last_name"] as? String]
                    .compactMap { $0 }.joined(separator: " ")
                let username = chat["username"] as? String
                return Chat(id: id, name: name.isEmpty ? (username ?? "you") : name, username: username)
            }
            guard updates.count >= 100, let newest else { return nil }
            offset = newest + 1
        }
        return nil
    }

    /// "/start <code>", "/start@<bot> <code>" or the bare code.
    static func answers(_ text: String, code: String, bot: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        switch words.count {
        case 1: return words[0] == code
        case 2: return (words[0] == "/start" || words[0].lowercased() == "/start@\(bot.lowercased())") && words[1] == code
        default: return false
        }
    }

    /// Sends `html` (Telegram HTML parse mode) to `chatId`. Too long is an
    /// error rather than a cut: a cut can land inside a tag, and then
    /// Telegram rejects the whole message (`UsageText` keeps within it).
    public func send(html: String, to chatId: Int64, markup: TelegramMarkup? = nil) async throws {
        guard html.utf16.count <= Self.maxMessageLength else {
            throw TelegramError("The message is \(html.utf16.count) characters long; Telegram takes \(Self.maxMessageLength)")
        }
        var body: [String: Any] = ["chat_id": chatId, "text": html, "parse_mode": "HTML", "disable_web_page_preview": true]
        if let markup { body["reply_markup"] = markup.json }
        _ = try await call("sendMessage", body: body)
    }

    /// Waits up to `timeout` seconds for messages after `offset` (long
    /// polling); asking past an update confirms it to Telegram.
    public func updates(after offset: Int64?, timeout: Int) async throws -> [[String: Any]] {
        var body: [String: Any] = ["timeout": timeout]
        if let offset { body["offset"] = offset }
        let result = try await call("getUpdates", body: body, timeout: TimeInterval(timeout) + 15)
        return (result as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// The newest waiting update's id, with every earlier one confirmed: a
    /// listener starts after what piled up while it was not running, so an
    /// old tap is not answered late. nil: nothing waits.
    public func skipBacklog() async throws -> Int64? {
        let result = try await call("getUpdates", body: ["offset": -1, "timeout": 0])
        return (result as? [Any] ?? []).compactMap { (($0 as? [String: Any])?["update_id"] as? NSNumber)?.int64Value }.max()
    }

    /// Stops the spinner on a pressed inline button.
    public func answerCallback(_ id: String, text: String? = nil) async throws {
        var body: [String: Any] = ["callback_query_id": id]
        if let text { body["text"] = text }
        _ = try await call("answerCallbackQuery", body: body)
    }

    /// The commands Telegram lists in the chat's menu, e.g. ("usage", "Show AI usage now").
    public func setCommands(_ commands: [(command: String, description: String)]) async throws {
        _ = try await call("setMyCommands", body: ["commands": commands.map { ["command": $0.command, "description": $0.description] }])
    }

    /// POSTs `body` as JSON to `bot<token>/<method>` and returns `result`.
    func call(_ method: String, body: [String: Any]?, timeout: TimeInterval = 15) async throws -> Any {
        guard Self.looksLikeToken(token) else {
            throw TelegramError("That does not look like a bot token (it should look like 123456789:AA…)")
        }
        var request = URLRequest(url: Self.base.appendingPathComponent("bot\(token)").appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        let data: Data
        let status: Int
        do {
            (data, status) = try await transport(request)
        } catch {
            // URLSession errors quote the URL, and the URL holds the token.
            throw TelegramError("Could not reach Telegram (\((error as NSError).code)): check the connection", kind: .transient)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if json?["ok"] as? Bool == true, let result = json?["result"] { return result }
        let description = json?["description"] as? String ?? "HTTP \(status)"
        let retryAfter = ((json?["parameters"] as? [String: Any])?["retry_after"] as? NSNumber)?.doubleValue
        throw TelegramError(Self.explain(description, status: status), kind: Self.kind(status: status),
                            retryAfter: retryAfter, status: status)
    }

    /// 429 (slow down) and server trouble pass; any other refusal stays
    /// until the token, the chat or the message changes.
    static func kind(status: Int) -> TelegramError.Kind {
        (400..<500).contains(status) && status != 429 ? .permanent : .transient
    }

    /// Telegram's own words, with the usual causes spelled out.
    static func explain(_ description: String, status: Int) -> String {
        switch status {
        case 401, 404: return "Telegram did not accept the bot token (\(description)). Copy it again from @BotFather."
        case 403: return "Telegram refused (\(description)). Open the chat with your bot and press Start."
        case 409 where description.lowercased().contains("webhook"):
            return "This bot sends its messages to a webhook, so they cannot be read here (\(description)). Make a new bot just for these alerts."
        case 409:
            return "Another program is reading this bot's messages right now (\(description)). Make a new bot just for these alerts, or stop that program and try again."
        case 429: return "Telegram asked to slow down (\(description))."
        default: return "Telegram said: \(description)"
        }
    }

    public static let urlSession: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Buttons a message can carry.
public enum TelegramMarkup: Equatable, Sendable {
    /// "📊 Usage" kept under the chat (a persistent reply keyboard): one tap
    /// any time asks for a report.
    case usageKeyboard
    /// "📊 Usage now" under the message itself (an inline button).
    case usageNowButton
    /// Takes the "📊 Usage" keyboard away (sharing stopped).
    case removeKeyboard

    var json: [String: Any] {
        switch self {
        case .usageKeyboard:
            return ["keyboard": [[["text": TelegramClient.usageButtonTitle]]], "resize_keyboard": true, "is_persistent": true]
        case .usageNowButton:
            return ["inline_keyboard": [[["text": "📊 Usage now", "callback_data": TelegramClient.usageCallbackData]]]]
        case .removeKeyboard:
            return ["remove_keyboard": true]
        }
    }
}

/// Someone in a private chat with the bot.
public struct TelegramPeer: Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var username: String?

    public init(id: Int64, name: String, username: String? = nil) {
        self.id = id
        self.name = name
        self.username = username
    }

    /// "Lim Wei (@limwei)".
    public var label: String { username.map { "\(name) (@\($0))" } ?? name }
}

/// What a message to the bot asks for, and who asks. Only private chats
/// count, and only a person writing in their own chat with the bot: the
/// owner, or anyone the bot was shared with (see TelegramViewers).
public enum TelegramRequest: Equatable, Sendable {
    /// "📊 Usage", /usage, /start or "usage" typed in the chat.
    case report(from: TelegramPeer)
    /// The "📊 Usage now" button under an alert; its callback is answered.
    case reportFromButton(callbackId: String, from: TelegramPeer)

    public var peer: TelegramPeer {
        switch self {
        case .report(let peer), .reportFromButton(_, let peer): return peer
        }
    }

    /// The request in `update`, if any. A message older than `maxAge` (typed
    /// while the Mac slept) is left unanswered.
    public static func parse(_ update: [String: Any], bot: String?, now: Date,
                             maxAge: TimeInterval = 600) -> TelegramRequest? {
        func id(_ object: Any?) -> Int64? { ((object as? [String: Any])?["id"] as? NSNumber)?.int64Value }
        if let message = update["message"] as? [String: Any] {
            guard let chat = message["chat"] as? [String: Any], chat["type"] as? String == "private",
                  let from = message["from"] as? [String: Any], from["is_bot"] as? Bool != true,
                  let person = id(from), id(chat) == person,
                  let text = message["text"] as? String, asksForUsage(text, bot: bot) else { return nil }
            if let sent = (message["date"] as? NSNumber)?.doubleValue, now.timeIntervalSince1970 - sent > maxAge { return nil }
            return .report(from: peer(person, from))
        }
        if let query = update["callback_query"] as? [String: Any] {
            // The button sits in the presser's own chat with the bot.
            guard let callbackId = query["id"] as? String, let from = query["from"] as? [String: Any],
                  let person = id(from), id((query["message"] as? [String: Any])?["chat"]) == person,
                  query["data"] as? String == TelegramClient.usageCallbackData else { return nil }
            return .reportFromButton(callbackId: callbackId, from: peer(person, from))
        }
        return nil
    }

    private static func peer(_ id: Int64, _ user: [String: Any]) -> TelegramPeer {
        let name = [user["first_name"] as? String, user["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
        let username = user["username"] as? String
        return TelegramPeer(id: id, name: name.isEmpty ? (username ?? "someone") : name, username: username)
    }

    /// The keyboard button's text, /usage (/usage@bot), /start, or "usage".
    static func asksForUsage(_ text: String, bot: String?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == TelegramClient.usageButtonTitle || trimmed.lowercased() == "usage" { return true }
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first?.lowercased() else { return false }
        let parts = first.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1] != bot?.lowercased() { return false }
        return parts.first == "/usage" || parts.first == "/start"
    }
}

/// The people other than the owner who get usage reports through the bot:
/// `state/telegram-viewers.json` (0600). Anyone who sends /usage in a
/// private chat with the bot gets a report at once and is listed here (never
/// the alerts). The owner can stop sharing with one of them, who then gets no
/// answer at all, and share again. Not thread-safe: the app uses it on the
/// main actor.
public final class TelegramViewers {
    public struct Viewer: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case allowed
            /// The owner stopped sharing with them.
            case blocked

            /// An earlier version's states read as their nearest ("pending"
            /// asked, and is let in now; "ignored" stays cut off). Anything
            /// unknown is cut off rather than let in.
            public init(from decoder: Decoder) throws {
                switch try decoder.singleValueContainer().decode(String.self) {
                case "allowed", "pending": self = .allowed
                default: self = .blocked
                }
            }
        }

        public var chatId: Int64
        public var name: String
        public var username: String?
        public var status: Status
        /// When they first asked, or when the owner last stopped or resumed sharing.
        public var since: Date

        public var label: String { TelegramPeer(id: chatId, name: name, username: username).label }
    }

    /// What a request from someone other than the owner gets.
    public enum Admission: Equatable, Sendable {
        /// Their first: a report, and a word on the 📊 Usage button.
        case first
        /// A report.
        case again
        /// Nothing: the owner stopped sharing with them.
        case blocked
    }

    /// The most kept. The longest-known allowed ones go first; a blocked one
    /// is never dropped, or new chats could push it out and let it back in.
    static let maxViewers = 100

    let url: URL
    public private(set) var all: [Viewer]

    public init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        all = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Viewer].self, from: $0) } ?? []
    }

    public static func standard() -> TelegramViewers {
        TelegramViewers(url: AppPaths.stateDir.appendingPathComponent("telegram-viewers.json"))
    }

    public func status(of chatId: Int64) -> Viewer.Status? { all.first { $0.chatId == chatId }?.status }

    public var allowed: [Viewer] { all.filter { $0.status == .allowed } }
    public var blocked: [Viewer] { all.filter { $0.status == .blocked } }

    /// Someone other than the owner asks for a report: let in at once and
    /// kept, their name current, unless the owner stopped sharing with them.
    @discardableResult
    public func admit(_ peer: TelegramPeer, now: Date) -> Admission {
        guard let index = all.firstIndex(where: { $0.chatId == peer.id }) else {
            all.append(Viewer(chatId: peer.id, name: peer.name, username: peer.username, status: .allowed, since: now))
            trim()
            save()
            return .first
        }
        guard all[index].status == .allowed else { return .blocked }
        if all[index].name != peer.name || all[index].username != peer.username {
            all[index].name = peer.name
            all[index].username = peer.username
            save()
        }
        return .again
    }

    /// "Stop Sharing": no answer for them any more. Nil unless they were
    /// getting reports.
    @discardableResult
    public func block(_ chatId: Int64, now: Date) -> Viewer? { set(.blocked, for: chatId, now: now) }

    /// "Share Again": reports again. Nil unless sharing with them was stopped.
    @discardableResult
    public func unblock(_ chatId: Int64, now: Date) -> Viewer? { set(.allowed, for: chatId, now: now) }

    public func clear() {
        all = []
        save()
    }

    private func set(_ status: Viewer.Status, for chatId: Int64, now: Date) -> Viewer? {
        guard let index = all.firstIndex(where: { $0.chatId == chatId }), all[index].status != status else { return nil }
        all[index].status = status
        all[index].since = now
        save()
        return all[index]
    }

    private func trim() {
        while all.count > Self.maxViewers, let index = all.firstIndex(where: { $0.status == .allowed }) {
            all.remove(at: index)
        }
    }

    private func save() {
        do {
            if all.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try OwnerOnlyFile.write(try encoder.encode(all), to: url)
        } catch {
            Log.shared.error("could not save \(url.path): \(error.localizedDescription)")
        }
    }
}

/// Usage alerts on their way to Telegram. Kept on disk until sent, so a
/// dropped connection, a sleeping Mac or a restart delays a message instead
/// of losing it; tried again with growing pauses, Telegram's "retry after"
/// honoured. A refusal that will not change by itself (revoked token,
/// blocked bot) drops the message and is reported, as is the last failure
/// of any kind. Not thread-safe: the app uses it on the main actor.
public final class TelegramOutbox {
    public struct Message: Codable, Equatable, Sendable {
        public var id: UUID
        public var html: String
        public var queuedAt: Date
        public var attempts: Int
        public var nextAttempt: Date
    }

    struct State: Codable, Equatable {
        var messages: [Message] = []
        /// Why the last attempt failed; nil once one succeeds.
        var problem: String?
        var problemSince: Date?
    }

    public enum Outcome: Equatable, Sendable {
        case retry(at: Date)
        case dropped
    }

    /// A usage alert older than this is old news: windows are five hours
    /// long, and the menu and the banner already said it.
    public static let maxAge: TimeInterval = 6 * 3600
    /// The oldest go first when more wait (a long offline stretch).
    public static let maxMessages = 20
    static let firstRetry: TimeInterval = 30
    static let longestRetry: TimeInterval = 15 * 60

    let url: URL
    private(set) var state: State

    public init(url: URL) {
        self.url = url
        state = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(State.self, from: $0) } ?? State()
    }

    public static func standard() -> TelegramOutbox {
        TelegramOutbox(url: AppPaths.stateDir.appendingPathComponent("telegram-outbox.json"))
    }

    public var pending: [Message] { state.messages }
    public var problem: String? { state.problem }
    public var problemSince: Date? { state.problemSince }

    public func enqueue(_ html: String, now: Date) {
        update { state in
            state.messages.append(Message(id: UUID(), html: html, queuedAt: now, attempts: 0, nextAttempt: now))
            if state.messages.count > Self.maxMessages { state.messages.removeFirst(state.messages.count - Self.maxMessages) }
        }
    }

    /// The oldest message due by `now`, after dropping the expired ones
    /// (returned in `expired` so the caller can say so).
    public func next(now: Date) -> (message: Message?, expired: Int) {
        var expired = 0
        update { state in
            let before = state.messages.count
            state.messages.removeAll { now.timeIntervalSince($0.queuedAt) > Self.maxAge }
            expired = before - state.messages.count
        }
        return (state.messages.first { $0.nextAttempt <= now }, expired)
    }

    /// When the earliest waiting message is due, for the menu.
    public var nextAttempt: Date? { state.messages.map(\.nextAttempt).min() }

    public func succeeded(_ id: UUID) {
        update { state in
            state.messages.removeAll { $0.id == id }
            state.problem = nil
            state.problemSince = nil
        }
    }

    @discardableResult
    public func failed(_ id: UUID, _ error: TelegramError, now: Date) -> Outcome {
        var outcome = Outcome.dropped
        update { state in
            if state.problem == nil { state.problemSince = now }
            state.problem = error.message
            guard let index = state.messages.firstIndex(where: { $0.id == id }) else { return }
            guard error.kind == .transient else {
                state.messages.remove(at: index)
                return
            }
            state.messages[index].attempts += 1
            let backoff = min(Self.firstRetry * pow(2, Double(state.messages[index].attempts - 1)), Self.longestRetry)
            let at = now.addingTimeInterval(max(backoff, min(error.retryAfter ?? 0, 3600)))
            state.messages[index].nextAttempt = at
            outcome = .retry(at: at)
        }
        return outcome
    }

    /// Everything forgotten: Telegram disconnected or turned off.
    public func clear() {
        update { $0 = State() }
    }

    /// A reconnect proved the chat works; what still waits goes there next.
    public func clearProblem(now: Date) {
        update { state in
            state.problem = nil
            state.problemSince = nil
            for index in state.messages.indices { state.messages[index].nextAttempt = now }
        }
    }

    private func update(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        do {
            if next == State() {
                try? FileManager.default.removeItem(at: url)
            } else {
                try OwnerOnlyFile.write(try Self.encoder.encode(next), to: url)
            }
        } catch {
            Log.shared.error("could not save \(url.path): \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
