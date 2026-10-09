import AISessionsCore
import AppKit

/// Connecting a Telegram bot from the menu, step by step in plain alerts.
/// The token is typed into a secure field here and written only to
/// `state/telegram.json` (0600): it never passes through a terminal, a
/// config file or a log.
@MainActor
enum TelegramSetup {
    /// Runs the whole flow; `completion` gets the saved settings, or nil when
    /// the user cancelled. `summary` adds the current usage table to the
    /// welcome message.
    static func run(summary: String?, completion: @escaping (TelegramSettings?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in completion(await flow(summary: summary)) }
    }

    private static func flow(summary: String?) async -> TelegramSettings? {
        // 1. The token.
        var client: TelegramClient
        var bot: TelegramClient.Bot
        while true {
            guard let token = askForToken() else { return nil }
            guard TelegramClient.looksLikeToken(token) else {
                show("That is not a bot token", "A token from @BotFather looks like 123456789:AAH… — digits, a colon, then a long code. Copy it again.")
                continue
            }
            client = TelegramClient(token: token)
            do {
                bot = try await client.me()
                break
            } catch {
                show("Telegram did not accept it", error.localizedDescription)
            }
        }
        // 2. The chat: Telegram lets a bot write only to people who wrote to it first.
        var chat: TelegramClient.Chat
        while true {
            switch askToSayHi(bot) {
            case .cancel: return nil
            case .openChat:
                if let url = URL(string: "https://t.me/\(bot.username)") { NSWorkspace.shared.open(url) }
                continue
            case .proceed:
                break
            }
            do {
                guard let found = try await client.newestPrivateChat() else {
                    show("No message yet", "Open @\(bot.username) in Telegram, press Start (or send it any message), then click Continue.")
                    continue
                }
                chat = found
            } catch {
                show("Could not read the bot's messages", error.localizedDescription)
                continue
            }
            break
        }
        // 3. Save, then prove it with a first message.
        let settings = TelegramSettings(botToken: client.token, chatId: chat.id, botUsername: bot.username, chatName: chat.name)
        do {
            try settings.save()
        } catch {
            show("Could not save the settings", error.localizedDescription)
            return nil
        }
        var welcome = "✅ <b>AI Sessions is connected.</b>\nYou will get a message here when a Claude or Codex usage limit passes the alert threshold."
        if let summary { welcome += "\n\n" + summary }
        do {
            try await client.send(html: welcome, to: chat.id)
            Log.shared.info("Telegram connected: \(settings.summary)")
            show("Telegram is connected", "Usage alerts will also go to \(settings.summary). A first message is waiting there.")
        } catch {
            Log.shared.warn("Telegram connected but the welcome message failed: \(error.localizedDescription)")
            show("Connected, but the first message failed", error.localizedDescription)
        }
        return settings
    }

    private static func askForToken() -> String? {
        let alert = NSAlert()
        alert.messageText = "Connect Telegram for usage alerts"
        alert.informativeText = """
            1. In Telegram, open @BotFather and send /newbot.
            2. Choose a name; BotFather replies with a token like 123456789:AAH…
            3. Paste that token below.

            It stays on this Mac, readable only by you (~/.ai-sessions/state/telegram.json).
            """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "123456789:AAH…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open @BotFather")
        alert.window.initialFirstResponder = field
        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            case .alertThirdButtonReturn:
                if let url = URL(string: "https://t.me/BotFather") { NSWorkspace.shared.open(url) }
            default:
                return nil
            }
        }
    }

    private enum SayHi { case proceed, cancel, openChat }

    private static func askToSayHi(_ bot: TelegramClient.Bot) -> SayHi {
        let alert = NSAlert()
        alert.messageText = "Now say hi to @\(bot.username)"
        alert.informativeText = "Open the chat with your bot in Telegram and press Start (or send it any message), then click Continue. That is how the bot learns where to send the alerts."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open @\(bot.username)")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .proceed
        case .alertThirdButtonReturn: return .openChat
        default: return .cancel
        }
    }

    static func show(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// "Disconnect Telegram…": asks first, then forgets the bot and chat.
    static func confirmDisconnect(_ settings: TelegramSettings) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop sending usage alerts to Telegram?"
        alert.informativeText = "AI Sessions forgets \(settings.summary). The bot itself stays in your Telegram; delete it in @BotFather if you no longer want it."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
