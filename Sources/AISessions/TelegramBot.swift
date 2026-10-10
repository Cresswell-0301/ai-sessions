import AISessionsCore
import Foundation

/// The listening side of the Telegram connection: "📊 Usage" (the button
/// kept under the chat), /usage, /start and the "📊 Usage now" button under
/// an alert each get a usage report back: in the owner's chat, and in anyone
/// else's who opens the bot (marked with whose Mac it is), except someone the
/// owner stopped sharing with.
/// Long-polls getUpdates while Telegram is connected and stops for the setup
/// flow, which reads the same updates (Telegram allows one reader).
@MainActor
final class TelegramBot {
    /// Builds the reply: a report after a fresh reading if it can, else why
    /// there is none. For a viewer, the owner's name ("◀ Cresswell's Mac").
    var report: @MainActor (_ ownerForViewer: String?) async -> String = { _ in "📊 No usage reading yet." }
    /// Called with why the bot stopped listening, or nil once it listens.
    var onProblem: (String?) -> Void = { _ in }
    /// Everyone else who gets reports, and anyone the owner stopped sharing with.
    var viewers = TelegramViewers.standard()
    /// Someone new got a report: the menu lists them.
    var onViewers: () -> Void = {}

    /// Seconds one getUpdates waits for a message.
    static let pollTimeout = 50
    /// A long poll that drops (connection lost, the Mac asleep) is routine:
    /// said only after this many failures in a row.
    static let failuresBeforeSaying = 4
    /// A second tap within this many seconds gets no second report.
    static let minGap: TimeInterval = 3

    private let transport: TelegramClient.Transport
    private let clock: () -> Date
    /// Seconds to wait after `failures` failures in a row (`status`: HTTP
    /// status, 409 waits longer); tests shorten it.
    var pauseAfter: (_ failures: Int, _ status: Int?) -> TimeInterval = { failures, status in
        failures == 1 ? 1 : min(5 * pow(2, Double(failures - 2)), status == 409 ? 600 : 300)
    }
    private(set) var settings: TelegramSettings?
    private var task: Task<Void, Never>?
    /// Per chat: a double tap in one chat must not cost someone else their report.
    private var lastReport: [Int64: Date] = [:]
    private var loggedProblem: String?
    /// Requests answered, for tests.
    private(set) var answered = 0

    init(transport: @escaping TelegramClient.Transport = TelegramClient.urlSession, clock: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.clock = clock
    }

    var isListening: Bool { task != nil }

    /// Listens for `settings`' chat (again, if it changed).
    func start(_ settings: TelegramSettings) {
        guard settings != self.settings || task == nil else { return }
        stop()
        self.settings = settings
        task = Task { [weak self] in await self?.listen(settings) }
    }

    func stop() {
        task?.cancel()
        task = nil
        settings = nil
    }

    /// The loop, until cancelled or the token stops working.
    private func listen(_ settings: TelegramSettings) async {
        let client = TelegramClient(token: settings.botToken, transport: transport)
        var offset: Int64?
        var started = false
        var failures = 0
        while !Task.isCancelled {
            do {
                if !started {
                    // What piled up while nothing listened is old: not answered.
                    offset = try await client.skipBacklog().map { $0 + 1 }
                    try? await client.setCommands([(command: "usage", description: "Show AI usage now")])
                    started = true
                    Log.shared.info("Telegram: listening for the Usage button (\(settings.summary))")
                }
                let updates = try await client.updates(after: offset, timeout: Self.pollTimeout)
                guard !Task.isCancelled else { return }
                failures = 0
                recovered()
                for update in updates {
                    if let id = (update["update_id"] as? NSNumber)?.int64Value { offset = max(offset ?? 0, id + 1) }
                    guard let request = TelegramRequest.parse(update, bot: settings.botUsername, now: clock()) else { continue }
                    await answer(request, client: client, settings: settings)
                }
            } catch {
                guard !Task.isCancelled else { return }
                let failure = TelegramError.from(error)
                // A revoked token never comes back by itself: stop, and say so.
                if let status = failure.status, [401, 403, 404].contains(status) {
                    report(problem: failure.message)
                    task = nil
                    return
                }
                // Asleep, offline, a dropped connection, or another program
                // reading this bot (409): try again, soon at first.
                failures += 1
                if failures >= Self.failuresBeforeSaying || failure.status == 409 { report(problem: failure.message) }
                try? await Task.sleep(nanoseconds: UInt64(pauseAfter(failures, failure.status) * 1_000_000_000))
            }
        }
    }

    /// One report per request, at most one per `minGap` per chat: to the
    /// owner, and to anyone else who asks (their first comes with a word on
    /// the button), except someone the owner stopped sharing with.
    private func answer(_ request: TelegramRequest, client: TelegramClient, settings: TelegramSettings) async {
        let peer = request.peer
        let isOwner = peer.id == settings.chatId
        let now = clock()
        let admission = isOwner ? .again : viewers.admit(peer, now: now)
        if admission == .first {
            Log.shared.info("Telegram: \(peer.label) started getting usage reports")
            onViewers()
        }
        let tooSoon = lastReport[peer.id].map { now.timeIntervalSince($0) < Self.minGap } ?? false
        if case .reportFromButton(let callbackId, _) = request {
            do {
                try await client.answerCallback(callbackId, text: admission == .blocked ? nil : tooSoon ? "Just sent" : "Checking usage…")
            } catch {
                // Too old to answer (tapped while the Mac slept): no late report either.
                Log.shared.info("Telegram: a Usage tap was too old to answer (\(TelegramError.from(error).message))")
                return
            }
        }
        // Someone the owner stopped sharing with gets no answer at all.
        guard admission != .blocked, !tooSoon else { return }
        lastReport[peer.id] = now
        let lead = admission == .first ? "👋 Tap <b>📊 Usage</b> below any time for the latest.\n\n" : ""
        if await send(lead + (await report(isOwner ? nil : settings.chatName ?? "the owner")), to: peer.id,
                      markup: .usageKeyboard, client: client) {
            answered += 1
            Log.shared.info("Telegram: usage report sent on request" + (isOwner ? "" : " to \(peer.label)"))
        }
    }

    @discardableResult
    private func send(_ html: String, to chatId: Int64, markup: TelegramMarkup?, client: TelegramClient) async -> Bool {
        do {
            try await client.send(html: html, to: chatId, markup: markup)
            return true
        } catch {
            Log.shared.warn("Telegram: a message to chat \(chatId) was NOT sent: \(TelegramError.from(error).message)")
            return false
        }
    }

    /// Tells a viewer the owner stopped sharing, and takes their button away.
    func sayStopped(to viewer: TelegramViewers.Viewer, owner: String, settings: TelegramSettings) async {
        let client = TelegramClient(token: settings.botToken, transport: transport)
        await send("🔒 \(UsageText.html(owner)) stopped sharing AI usage with you.", to: viewer.chatId, markup: .removeKeyboard, client: client)
    }

    /// Tells a viewer the owner shares again, and gives the button back.
    func sayShared(to viewer: TelegramViewers.Viewer, owner: String, settings: TelegramSettings) async {
        let client = TelegramClient(token: settings.botToken, transport: transport)
        await send("🔓 \(UsageText.html(owner)) is sharing AI usage with you again. Tap <b>📊 Usage</b> below any time.",
                   to: viewer.chatId, markup: .usageKeyboard, client: client)
    }

    private func report(problem: String) {
        guard loggedProblem != problem else { return }
        loggedProblem = problem
        Log.shared.warn("Telegram: not listening for the Usage button: \(problem)")
        onProblem(problem)
    }

    private func recovered() {
        guard loggedProblem != nil else { return }
        loggedProblem = nil
        Log.shared.info("Telegram: listening again")
        onProblem(nil)
    }
}
