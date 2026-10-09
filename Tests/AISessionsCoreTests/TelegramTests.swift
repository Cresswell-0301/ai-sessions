import XCTest
@testable import AISessionsCore

/// The Telegram side: requests the Bot API gets, answers it gives, and that
/// the bot token never leaks into an error or onto disk for anyone else.
final class TelegramTests: XCTestCase {
    private let token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"

    /// Records requests and answers with canned JSON.
    private final class FakeTelegram: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answers: [String: (Int, String)] = [:]
        var failure: Error?

        func transport() -> TelegramClient.Transport {
            { [self] request in
                requests.append(request)
                if let failure { throw failure }
                let method = request.url!.lastPathComponent
                let (status, body) = answers[method] ?? (404, #"{"ok":false,"description":"Not Found"}"#)
                return (Data(body.utf8), status)
            }
        }

        func body(_ index: Int) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
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

    func testTheChatIsTheNewestPrivateOneThatWroteToTheBot() async throws {
        let fake = FakeTelegram()
        fake.answers["getUpdates"] = (200, """
            {"ok":true,"result":[
             {"update_id":1,"message":{"chat":{"id":111,"type":"private","first_name":"Old"}}},
             {"update_id":2,"message":{"chat":{"id":-500,"type":"group","title":"Team"}}},
             {"update_id":3,"message":{"chat":{"id":222,"type":"private","first_name":"Cress","last_name":"Well"}}},
             {"update_id":4,"edited_message":{"chat":{"id":333,"type":"private"}}}
            ]}
            """)
        let chat = try await TelegramClient(token: token, transport: fake.transport()).newestPrivateChat()
        XCTAssertEqual(chat, TelegramClient.Chat(id: 222, name: "Cress Well"))

        fake.answers["getUpdates"] = (200, #"{"ok":true,"result":[]}"#)
        let none = try await TelegramClient(token: token, transport: fake.transport()).newestPrivateChat()
        XCTAssertNil(none, "nobody pressed Start yet")
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
        TelegramSettings.delete(at: url)
        XCTAssertNil(TelegramSettings.load(from: url))
    }
}
