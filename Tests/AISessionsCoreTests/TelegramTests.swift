import XCTest
@testable import AISessionsCore

/// The Telegram side: requests the Bot API gets, answers it gives, and that
/// the bot token never leaks into an error or onto disk for anyone else.
final class TelegramTests: XCTestCase {
    private let token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"
    private let t0 = Date(timeIntervalSince1970: 1_791_600_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Records requests and answers with canned JSON.
    private final class FakeTelegram: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answers: [String: (Int, String)] = [:]
        /// Answers by method and request body, when set (paging).
        var responder: ((String, [String: Any]) -> (Int, String))?
        var failure: Error?

        func transport() -> TelegramClient.Transport {
            { [self] request in
                requests.append(request)
                if let failure { throw failure }
                let method = request.url!.lastPathComponent
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let (status, text) = responder?(method, body)
                    ?? answers[method] ?? (404, #"{"ok":false,"description":"Not Found"}"#)
                return (Data(text.utf8), status)
            }
        }

        /// Request `index`'s JSON body; empty when there was no such request
        /// (a failed assertion, not a crash that hides the others).
        func body(_ index: Int) -> [String: Any] {
            guard requests.indices.contains(index) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
        }
    }

    func testTokenShape() {
        XCTAssertTrue(TelegramClient.looksLikeToken(token))
        XCTAssertTrue(TelegramClient.looksLikeToken("  \(token)\n"), "surrounding whitespace from a paste is fine")
        XCTAssertFalse(TelegramClient.looksLikeToken("123456789"))
        XCTAssertFalse(TelegramClient.looksLikeToken("abc:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"))
        XCTAssertFalse(TelegramClient.looksLikeToken("123:short"))
        XCTAssertFalse(TelegramClient.looksLikeToken("123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PA/../x"), "no path characters")
    }

    func testAMalformedTokenNeverReachesTelegram() async {
        let fake = FakeTelegram()
        let client = TelegramClient(token: "not-a-token", transport: fake.transport())
        do {
            _ = try await client.me()
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not look like a bot token"))
        }
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testMeNamesTheBot() async throws {
        let fake = FakeTelegram()
        fake.answers["getMe"] = (200, #"{"ok":true,"result":{"id":1,"is_bot":true,"first_name":"Usage","username":"my_usage_bot"}}"#)
        let bot = try await TelegramClient(token: token, transport: fake.transport()).me()
        XCTAssertEqual(bot, TelegramClient.Bot(username: "my_usage_bot", name: "Usage"))
        XCTAssertEqual(fake.requests.first?.url?.absoluteString, "https://api.telegram.org/bot\(token)/getMe")
        XCTAssertEqual(fake.requests.first?.httpMethod, "POST")
    }

    // MARK: Which chat gets the alerts

    private func update(_ id: Int, chat: Int64, type: String = "private", text: String?,
                        first: String = "Cress", last: String? = nil, username: String? = nil) -> String {
        var chatJSON: [String: Any] = ["id": chat, "type": type, "first_name": first]
        if let last { chatJSON["last_name"] = last }
        if let username { chatJSON["username"] = username }
        var message: [String: Any] = ["message_id": id, "date": 1_791_600_000, "chat": chatJSON]
        if let text { message["text"] = text }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["update_id": id, "message": message]), as: UTF8.self)
    }

    private func updates(_ items: [String]) -> String { #"{"ok":true,"result":["# + items.joined(separator: ",") + "]}" }

    func testOnlyTheChatThatSentThisSetupsCodeIsTaken() async throws {
        let fake = FakeTelegram()
        let code = "4f2a9c01be"
        fake.answers["getUpdates"] = (200, updates([
            update(1, chat: 111, text: "/start", first: "Stranger"),
            update(2, chat: 112, text: "/start 0000000000", first: "Guesser"),
            update(3, chat: -500, type: "group", text: "/start \(code)", first: "Team"),
            update(4, chat: 222, text: "/start \(code)", first: "Cress", last: "Well", username: "cresswell"),
            update(5, chat: 333, text: "hello", first: "Later"),
        ]))
        let client = TelegramClient(token: token, transport: fake.transport())
        let chat = try await client.chatThatSent(code: code, bot: "my_usage_bot")
        XCTAssertEqual(chat, TelegramClient.Chat(id: 222, name: "Cress Well", username: "cresswell"))
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertNil(fake.body(0)["allowed_updates"], "the bot's update filter belongs to whoever else uses it")
        XCTAssertNil(fake.body(0)["offset"], "a first look acknowledges nothing")

        fake.answers["getUpdates"] = (200, updates([update(1, chat: 111, text: "/start", first: "Stranger"),
                                                    update(2, chat: 112, text: "hi", first: "Someone")]))
        let stranger = try await client.chatThatSent(code: code, bot: "my_usage_bot")
        XCTAssertNil(stranger, "a stranger pressing Start is not the user, however recent")
        fake.answers["getUpdates"] = (200, updates([]))
        let nobody = try await client.chatThatSent(code: code, bot: "my_usage_bot")
        XCTAssertNil(nobody)
    }

    func testTheCodeMayBeTypedInstead() {
        let bot = "My_Usage_Bot"
        XCTAssertTrue(TelegramClient.answers("/start 4f2a9c01be", code: "4f2a9c01be", bot: bot))
        XCTAssertTrue(TelegramClient.answers("  4f2a9c01be\n", code: "4f2a9c01be", bot: bot), "the bare code")
        XCTAssertTrue(TelegramClient.answers("/start@my_usage_bot 4f2a9c01be", code: "4f2a9c01be", bot: bot))
        XCTAssertFalse(TelegramClient.answers("/start@other_bot 4f2a9c01be", code: "4f2a9c01be", bot: bot))
        XCTAssertFalse(TelegramClient.answers("/start 4f2a9c01b", code: "4f2a9c01be", bot: bot))
        XCTAssertFalse(TelegramClient.answers("/start 4f2a9c01be please", code: "4f2a9c01be", bot: bot))
        XCTAssertFalse(TelegramClient.answers("/stop 4f2a9c01be", code: "4f2a9c01be", bot: bot))
        XCTAssertFalse(TelegramClient.answers("", code: "4f2a9c01be", bot: bot))
    }

    func testAFullPageOfUpdatesIsReadPast() async throws {
        let fake = FakeTelegram()
        let code = "aaaaabbbbb"
        fake.responder = { [self] method, body in
            guard method == "getUpdates" else { return (404, #"{"ok":false,"description":"Not Found"}"#) }
            switch (body["offset"] as? NSNumber)?.intValue {
            case nil: return (200, updates((1...100).map { update($0, chat: 111, text: "spam \($0)", first: "Spam") }))
            case 101?: return (200, updates([update(101, chat: 222, text: "/start \(code)")]))
            default: return (200, updates([]))
            }
        }
        let chat = try await TelegramClient(token: token, transport: fake.transport()).chatThatSent(code: code, bot: "b")
        XCTAssertEqual(chat?.id, 222, "the code sat behind 100 other updates")
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual((fake.body(1)["offset"] as? NSNumber)?.intValue, 101)
    }

    func testEachSetupHasItsOwnCode() {
        let a = TelegramClient.makeStartCode(), b = TelegramClient.makeStartCode()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 10)
        XCTAssertTrue(a.allSatisfy(\.isHexDigit), a)
        XCTAssertEqual(TelegramClient.startLink(bot: "my_usage_bot", code: a)?.absoluteString, "https://t.me/my_usage_bot?start=\(a)")
    }

    func testSendPostsHTMLToTheChat() async throws {
        let fake = FakeTelegram()
        fake.answers["sendMessage"] = (200, #"{"ok":true,"result":{"message_id":9}}"#)
        try await TelegramClient(token: token, transport: fake.transport()).send(html: "<b>hi</b>", to: 222)
        let body = fake.body(0)
        XCTAssertEqual(body["chat_id"] as? Int, 222)
        XCTAssertEqual(body["text"] as? String, "<b>hi</b>")
        XCTAssertEqual(body["parse_mode"] as? String, "HTML")
        XCTAssertEqual(fake.requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testAnOverlongMessageIsRefusedNotCut() async throws {
        let fake = FakeTelegram()
        fake.answers["sendMessage"] = (200, #"{"ok":true,"result":{"message_id":9}}"#)
        let client = TelegramClient(token: token, transport: fake.transport())
        let long = "<pre>" + String(repeating: "x", count: 5000) + "</pre>"
        do {
            try await client.send(html: long, to: 1)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? TelegramError)?.kind, .permanent)
        }
        XCTAssertTrue(fake.requests.isEmpty, "nothing half-sent: a cut inside <pre> would be refused anyway")
        let full = String(repeating: "y", count: TelegramClient.maxMessageLength)
        try await client.send(html: full, to: 1)
        XCTAssertEqual(fake.body(0)["text"] as? String, full, "exactly the limit goes whole")
    }

    func testErrorsSayWhetherTryingAgainCanHelp() async {
        let fake = FakeTelegram()
        let client = TelegramClient(token: token, transport: fake.transport())
        func failure(_ status: Int, _ body: String) async -> TelegramError? {
            fake.answers["sendMessage"] = (status, body)
            do { try await client.send(html: "x", to: 1); return nil } catch { return error as? TelegramError }
        }
        let slowDown = await failure(429, #"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 7","parameters":{"retry_after":7}}"#)
        XCTAssertEqual(slowDown?.kind, .transient)
        XCTAssertEqual(slowDown?.retryAfter, 7)
        let down = await failure(502, "<html>Bad Gateway</html>")
        XCTAssertEqual(down?.kind, .transient)
        XCTAssertEqual(down?.message, "Telegram said: HTTP 502")
        let blocked = await failure(403, #"{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}"#)
        XCTAssertEqual(blocked?.kind, .permanent)
        let badChat = await failure(400, #"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#)
        XCTAssertEqual(badChat?.kind, .permanent)
        fake.failure = URLError(.timedOut)
        let offline = await failure(200, "")
        XCTAssertEqual(offline?.kind, .transient)
        XCTAssertEqual(TelegramError.from(URLError(.timedOut)).kind, .transient, "a foreign error is worth another try")
    }

    func testAConflictNamesItsCause() {
        let webhook = TelegramClient.explain("Conflict: can't use getUpdates method while webhook is active; use deleteWebhook to delete the webhook first", status: 409)
        XCTAssertTrue(webhook.contains("sends its messages to a webhook"), webhook)
        let poller = TelegramClient.explain("Conflict: terminated by other getUpdates request; make sure that only one bot instance is running", status: 409)
        XCTAssertTrue(poller.contains("Another program is reading"), poller)
    }

    func testErrorsExplainWithoutTheToken() async {
        let fake = FakeTelegram()
        fake.answers["getMe"] = (401, #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#)
        fake.answers["sendMessage"] = (403, #"{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}"#)
        let client = TelegramClient(token: token, transport: fake.transport())
        do { _ = try await client.me(); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("@BotFather"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
        do { try await client.send(html: "x", to: 1); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("press Start"), error.localizedDescription)
        }
        // A network failure: URLSession's error quotes the URL, which holds the token.
        fake.failure = URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLStringErrorKey:
            "https://api.telegram.org/bot\(token)/sendMessage"])
        do { try await client.send(html: "x", to: 1); XCTFail() } catch {
            XCTAssertFalse(error.localizedDescription.contains(token), error.localizedDescription)
            XCTAssertFalse(String(describing: error).contains(token))
        }
    }

    func testSettingsAreOwnerOnlyAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-\(UUID().uuidString)/state")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let url = dir.appendingPathComponent("telegram.json")
        let settings = TelegramSettings(botToken: token, chatId: 222, botUsername: "my_usage_bot", chatName: "Cress")
        try settings.save(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(TelegramSettings.load(from: url), settings)
        try TelegramSettings(botToken: token, chatId: 333).save(to: url)
        XCTAssertEqual(TelegramSettings.load(from: url)?.chatId, 333, "a re-connect replaces the file")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(settings.summary, "@my_usage_bot → Cress")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["telegram.json"], "no temp copy left")
        TelegramSettings.delete(at: url)
        XCTAssertNil(TelegramSettings.load(from: url))
    }

    func testDisconnectAlsoRemovesATempCopyACrashLeft() throws {
        let state = dir.appendingPathComponent("state")
        let url = state.appendingPathComponent("telegram.json")
        try TelegramSettings(botToken: token, chatId: 222).save(to: url)
        let leftover = state.appendingPathComponent(".telegram.json.\(UUID().uuidString).tmp")
        XCTAssertTrue(FileManager.default.createFile(atPath: leftover.path, contents: Data(token.utf8)))
        let neighbour = state.appendingPathComponent("state.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: neighbour.path, contents: Data("{}".utf8)))
        TelegramSettings.delete(at: url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: state.path), ["state.json"],
                       "the token's copies are gone, nothing else")
    }

    // MARK: Outbox

    private func outbox(_ name: String = "outbox.json") -> TelegramOutbox {
        TelegramOutbox(url: dir.appendingPathComponent(name))
    }

    func testAFailedSendWaitsLongerEachTimeAndHonoursRetryAfter() throws {
        let box = outbox()
        box.enqueue("one", now: t0)
        let message = try XCTUnwrap(box.next(now: t0).message)
        let offline = TelegramError("Could not reach Telegram", kind: .transient)
        XCTAssertEqual(box.failed(message.id, offline, now: t0), .retry(at: t0 + 30))
        XCTAssertNil(box.next(now: t0 + 29).message, "not before its pause is over")
        XCTAssertEqual(box.next(now: t0 + 30).message?.id, message.id)
        XCTAssertEqual(box.failed(message.id, offline, now: t0 + 30), .retry(at: t0 + 90), "then 60 s")
        let slowDown = TelegramError("Telegram asked to slow down", kind: .transient, retryAfter: 600)
        XCTAssertEqual(box.failed(message.id, slowDown, now: t0 + 90), .retry(at: t0 + 690), "Telegram's own pause, when longer")
        XCTAssertEqual(box.problem, "Telegram asked to slow down")
        XCTAssertEqual(box.problemSince, t0, "since the first failure")
        for _ in 0..<10 { box.failed(message.id, offline, now: t0) }
        XCTAssertEqual(box.nextAttempt, t0 + 900, "pauses stop growing at 15 min")
        box.succeeded(message.id)
        XCTAssertTrue(box.pending.isEmpty)
        XCTAssertNil(box.problem, "one success clears the problem")
    }

    func testARefusalDropsThatMessageAndKeepsTheReason() throws {
        let box = outbox()
        box.enqueue("one", now: t0)
        box.enqueue("two", now: t0 + 1)
        let first = try XCTUnwrap(box.next(now: t0 + 1).message)
        XCTAssertEqual(first.html, "one", "oldest first")
        XCTAssertEqual(box.failed(first.id, TelegramError("Forbidden: bot was blocked by the user"), now: t0 + 2), .dropped)
        XCTAssertEqual(box.pending.map(\.html), ["two"])
        XCTAssertEqual(box.problem, "Forbidden: bot was blocked by the user")
    }

    func testOldNewsIsDroppedAndTheQueueIsBounded() {
        let box = outbox()
        box.enqueue("old", now: t0)
        box.enqueue("new", now: t0 + TelegramOutbox.maxAge)
        let (message, expired) = box.next(now: t0 + TelegramOutbox.maxAge + 1)
        XCTAssertEqual(expired, 1)
        XCTAssertEqual(message?.html, "new")
        for i in 0..<25 { box.enqueue("m\(i)", now: t0 + TelegramOutbox.maxAge) }
        XCTAssertEqual(box.pending.count, TelegramOutbox.maxMessages)
        XCTAssertEqual(box.pending.last?.html, "m24", "the newest are kept")
    }

    func testTheOutboxOutlivesARestartAndIsOwnerOnly() throws {
        let url = dir.appendingPathComponent("state/telegram-outbox.json")
        let box = TelegramOutbox(url: url)
        box.enqueue("waiting", now: t0)
        box.failed(try XCTUnwrap(box.pending.first).id, TelegramError("Could not reach Telegram", kind: .transient), now: t0)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let restarted = TelegramOutbox(url: url)
        XCTAssertEqual(restarted.pending, box.pending)
        XCTAssertEqual(restarted.problem, "Could not reach Telegram")
        restarted.clearProblem(now: t0 + 5)
        XCTAssertNil(restarted.problem)
        XCTAssertEqual(restarted.next(now: t0 + 5).message?.html, "waiting", "a reconnect sends what waits right away")
        restarted.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing to keep, no file")
    }
}
