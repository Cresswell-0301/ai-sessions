import AISessionsCore
import AppKit

/// Connecting a Telegram bot from the menu, step by step in plain alerts.
/// The token is typed into a secure field here and written only to
/// `state/telegram.json` (0600): it never passes through a terminal, a
/// config file or a log.
@MainActor
enum TelegramSetup {
    /// One setup at a time: a second click while the first waits on Telegram
    /// would stack two flows, each with its own token, on top of each other.
    private(set) static var isRunning = false

    /// Runs the whole flow; `completion` gets the saved settings, or nil when
    /// the user cancelled. `snapshot`'s usage goes into the welcome message.
    /// While a setup is open this only brings it forward and returns false.
    @discardableResult
    static func run(view: UsageView?, completion: @escaping (TelegramSettings?) -> Void) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return run({ await flow(view: view) }, completion: completion)
    }

    /// The guard around any flow (tests pass one that waits on them).
    static func run(_ flow: @escaping @MainActor () async -> TelegramSettings?,
                    completion: @escaping (TelegramSettings?) -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        Task { @MainActor in
            let settings = await flow()
            isRunning = false
            completion(settings)
        }
        return true
    }

    private static func flow(view: UsageView?) async -> TelegramSettings? {
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
        // 2. The chat. A bot may write only to people who wrote to it first,
        // and anyone can write to a bot: only the chat that answers this
        // setup's code is taken, and only after the user says it is theirs.
        let code = TelegramClient.makeStartCode()
        var chat: TelegramClient.Chat
        while true {
            switch askToPressStart(bot, code: code) {
            case .cancel: return nil
            case .openChat:
                if let url = TelegramClient.startLink(bot: bot.username, code: code) { NSWorkspace.shared.open(url) }
                continue
            case .proceed:
                break
            }
            let found: TelegramClient.Chat?
            do {
                found = try await client.chatThatSent(code: code, bot: bot.username)
            } catch {
                show("Could not read the bot's messages", error.localizedDescription)
                continue
            }
            guard let found else {
                show("Not there yet", "@\(bot.username) has not received this setup's code. Click Open @\(bot.username) and press START in Telegram (or send the bot this message: /start \(code)), then click Continue.")
                continue
            }
            guard confirm(found, bot: bot) else { return nil }
            chat = found
            break
        }
        // 3. Save, then prove it with a first message.
        let settings = TelegramSettings(botToken: client.token, chatId: chat.id, botUsername: bot.username, chatName: chat.name,
                                        keyboardShown: true)
        do {
            try settings.save()
        } catch {
            show("Could not save the settings", error.localizedDescription)
            return nil
        }
        let cleared = clearClipboard(ifItHolds: client.token)
        let lead = "✅ <b>AI Sessions is connected.</b>\nYou will get a message here when the account this Mac uses passes "
            + "the usage alert threshold. Tap <b>📊 Usage</b> below (or send /usage) any time to see it now."
        let welcome = view.map { UsageText.reportMessage($0, lead: lead) } ?? lead
        do {
            try await client.send(html: welcome, to: chat.id, markup: .usageKeyboard)
            Log.shared.info("Telegram connected: \(settings.summary)")
            show("Telegram is connected", "Usage alerts will also go to \(settings.summary). A first message is waiting there."
                + (cleared ? "\n\nThe token was also cleared from the clipboard." : ""))
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
            3. Paste that token below (⌘V).

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
            switch present(alert) {
            case .alertFirstButtonReturn:
                return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            case .alertThirdButtonReturn:
                if let url = URL(string: "https://t.me/BotFather") { NSWorkspace.shared.open(url) }
            default:
                return nil
            }
        }
    }

    private enum PressStart { case proceed, cancel, openChat }

    private static func askToPressStart(_ bot: TelegramClient.Bot, code: String) -> PressStart {
        let alert = NSAlert()
        alert.messageText = "Now press Start in @\(bot.username)"
        alert.informativeText = """
            Click Open @\(bot.username): Telegram opens the chat with your bot. Press START there, then come back and click Continue.

            No START button? Send the bot this message instead:
            /start \(code)

            The code is new for each setup, so only you can connect this bot to this Mac.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open @\(bot.username)")
        switch present(alert) {
        case .alertFirstButtonReturn: return .proceed
        case .alertThirdButtonReturn: return .openChat
        default: return .cancel
        }
    }

    /// Names the chat before anything is saved or sent to it.
    private static func confirm(_ chat: TelegramClient.Chat, bot: TelegramClient.Bot) -> Bool {
        let alert = NSAlert()
        let who = chat.username.map { "\(chat.name) (@\($0))" } ?? chat.name
        alert.messageText = "Send usage alerts to \(who)?"
        alert.informativeText = "This Telegram account answered this setup's code in its chat with @\(bot.username). Alerts, with every account's usage, will go there."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        return present(alert) == .alertFirstButtonReturn
    }

    /// The token was copied out of Telegram to be pasted here. Once it is
    /// saved it should not linger where clipboard history or Universal
    /// Clipboard can carry it; only that exact text is cleared.
    private static func clearClipboard(ifItHolds token: String) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == token else {
            return false
        }
        pasteboard.clearContents()
        return true
    }

    static func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    /// Every dialog comes to the front: the app has no Dock icon or windows,
    /// and its alert would otherwise open behind whatever app is in use.
    @discardableResult
    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// "Stop Sharing with …": asks first.
    static func confirmStopSharing(_ viewer: TelegramViewers.Viewer) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop sharing AI usage with \(viewer.name)?"
        alert.informativeText = "The bot will no longer answer \(viewer.label), and their 📊 Usage button goes away. Share Again, in the same menu, undoes it."
        alert.addButton(withTitle: "Stop Sharing")
        alert.addButton(withTitle: "Cancel")
        return present(alert) == .alertFirstButtonReturn
    }

    /// "Disconnect Telegram…": asks first, then forgets the bot and chat.
    static func confirmDisconnect(_ settings: TelegramSettings) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop sending usage alerts to Telegram?"
        alert.informativeText = "AI Sessions forgets \(settings.summary), the people you share usage with, and any alert still waiting to be sent. The bot itself stays in your Telegram; delete it in @BotFather if you no longer want it."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        return present(alert) == .alertFirstButtonReturn
    }
}

/// The app's main menu. An accessory app shows no menu bar, but without an
/// Edit menu nothing turns ⌘V into Paste: the bot token could not be pasted
/// into the setup's field. Never visible; its key equivalents reach the
/// focused field through the responder chain (nil targets).
enum AppMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        // The first item is the application menu by convention.
        main.addItem(NSMenuItem(title: AppInfo.name, action: nil, keyEquivalent: ""))
        main.items[0].submenu = NSMenu(title: AppInfo.name)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
