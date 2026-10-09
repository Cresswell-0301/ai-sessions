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

    public init(botToken: String, chatId: Int64, botUsername: String? = nil, chatName: String? = nil) {
        self.botToken = botToken
        self.chatId = chatId
        self.botUsername = botUsername
        self.chatName = chatName
    }

    public static var standardURL: URL { AppPaths.stateDir.appendingPathComponent("telegram.json") }

    public static func load(from url: URL = standardURL) -> TelegramSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TelegramSettings.self, from: data)
    }

    /// Written 0600 from the start (no window where it is world-readable).
    public func save(to url: URL = standardURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".telegram-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: try JSONEncoder().encode(self),
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) } else { try fm.moveItem(at: temp, to: url) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func delete(at url: URL = standardURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// "@ai_sessions_bot → Cresswell".
    public var summary: String {
        let bot = botUsername.map { "@\($0)" } ?? "your bot"
        return chatName.map { "\(bot) → \($0)" } ?? bot
    }
}

/// What can go wrong talking to Telegram, in words fit for an alert.
/// Never carries the token: request URLs contain it, so they are not kept.
public struct TelegramError: Error, Equatable, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
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
    }

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

    /// Which bot the token belongs to (and that it works at all).
    public func me() async throws -> Bot {
        let result = try await call("getMe", body: nil)
        guard let bot = result as? [String: Any], let username = bot["username"] as? String else {
            throw TelegramError("Telegram answered getMe without a bot name")
        }
        return Bot(username: username, name: bot["first_name"] as? String ?? username)
    }

    /// The newest private chat that wrote to the bot: the user pressed Start
    /// (or sent anything) after creating it. nil when nobody has yet.
    public func newestPrivateChat() async throws -> Chat? {
        let result = try await call("getUpdates", body: ["timeout": 0, "allowed_updates": ["message"]])
        guard let updates = result as? [Any] else { return nil }
        for case let update as [String: Any] in updates.reversed() {
            guard let message = update["message"] as? [String: Any],
                  let chat = message["chat"] as? [String: Any], chat["type"] as? String == "private",
                  let id = (chat["id"] as? NSNumber)?.int64Value else { continue }
            let name = [chat["first_name"] as? String, chat["last_name"] as? String]
                .compactMap { $0 }.joined(separator: " ")
            return Chat(id: id, name: name.isEmpty ? (chat["username"] as? String ?? "you") : name)
        }
        return nil
    }

    /// Sends `html` (Telegram HTML parse mode) to `chatId`.
    public func send(html: String, to chatId: Int64) async throws {
        _ = try await call("sendMessage", body: [
            "chat_id": chatId, "text": String(html.prefix(4000)), "parse_mode": "HTML",
            "disable_web_page_preview": true,
        ])
    }

    /// POSTs `body` as JSON to `bot<token>/<method>` and returns `result`.
    func call(_ method: String, body: [String: Any]?) async throws -> Any {
        guard Self.looksLikeToken(token) else {
            throw TelegramError("That does not look like a bot token (it should look like 123456789:AA…)")
        }
        var request = URLRequest(url: Self.base.appendingPathComponent("bot\(token)").appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        let data: Data
        let status: Int
        do {
            (data, status) = try await transport(request)
        } catch {
            // URLSession errors quote the URL, and the URL holds the token.
            throw TelegramError("Could not reach Telegram (\((error as NSError).code)): check the connection")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if json?["ok"] as? Bool == true, let result = json?["result"] { return result }
        let description = json?["description"] as? String ?? "HTTP \(status)"
        throw TelegramError(Self.explain(description, status: status))
    }

    /// Telegram's own words, with the usual causes spelled out.
    static func explain(_ description: String, status: Int) -> String {
        switch status {
        case 401, 404: return "Telegram did not accept the bot token (\(description)). Copy it again from @BotFather."
        case 403: return "Telegram refused (\(description)). Open the chat with your bot and press Start."
        case 409: return "This bot has a webhook set, so it cannot read messages here (\(description))."
        default: return "Telegram said: \(description)"
        }
    }

    public static let urlSession: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
