import AISessionsCore
import Foundation

/// The listening side of the Telegram connection: "📊 Usage" (the button
/// kept under the chat), /usage, /start and the "📊 Usage now" button under
/// an alert each get a usage report back. The owner's chat is answered, and
/// so is anyone the owner allowed; someone new is asked to wait while the
/// owner gets Allow / Ignore buttons, and an ignored one gets nothing.
/// Long-polls getUpdates while Telegram is connected and stops for the setup
/// flow, which reads the same updates (Telegram allows one reader).
@MainActor
final class TelegramBot {
    /// Builds the reply: a report after a fresh reading if it can, else why
    /// there is none. For a viewer, the owner's name ("◀ Cresswell's Mac").
    var report: @MainActor (_ ownerForViewer: String?) async -> String = { _ in "📊 No usage reading yet." }
    /// Called with why the bot stopped listening, or nil once it listens.
    var onProblem: (String?) -> Void = { _ in }
    /// The people the owner shares reports with, and the ones who asked.
    var viewers = TelegramViewers.standard()
    /// Someone asked, or the owner decided: the menu lists them.
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
    private var lastWaitNote: [Int64: Date] = [:]
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

    /// One report per request, at most one per `minGap` per chat, to the
    /// owner or someone the owner allowed; everyone else asks first.
    private func answer(_ request: TelegramRequest, client: TelegramClient, settings: TelegramSettings) async {
        let peer = request.peer
        let isOwner = peer.id == settings.chatId
        let ownerName = settings.chatName ?? "the owner"
        let now = clock()
        if case .decision(let callbackId, _, let viewerId, let allow) = request {
            // Only the owner decides; anyone else's press of such a button does nothing.
            guard isOwner else { return }
            let decided = viewers.decide(viewerId, allow: allow, now: now)
            onViewers()
            try? await client.answerCallback(callbackId, text: decided.map { allow ? "Allowed \($0.name)" : "Ignored \($0.name)" }
                                                 ?? "Already answered")
            guard allow, let viewer = decided else { return }
            Log.shared.info("Telegram: \(viewer.label) may now see usage reports")
            lastReport[viewer.chatId] = now
            let welcome = "✅ \(UsageText.html(ownerName)) let you see AI usage. Tap <b>📊 Usage</b> below any time.\n\n"
            if await send(welcome + (await report(ownerName)), to: viewer.chatId, markup: .usageKeyboard, client: client) { answered += 1 }
            return
        }
        let allowed = isOwner || viewers.status(of: peer.id) == .allowed
        let tooSoon = lastReport[peer.id].map { now.timeIntervalSince($0) < Self.minGap } ?? false
        if case .reportFromButton(let callbackId, _) = request {
            do {
                try await client.answerCallback(callbackId, text: allowed ? (tooSoon ? "Just sent" : "Checking usage…") : nil)
            } catch {
                // Too old to answer (tapped while the Mac slept): no late report either.
                Log.shared.info("Telegram: a Usage tap was too old to answer (\(TelegramError.from(error).message))")
                return
            }
        }
        if allowed {
            guard !tooSoon else { return }
            lastReport[peer.id] = now
            if await send(await report(isOwner ? nil : ownerName), to: peer.id, markup: .usageKeyboard, client: client) {
                answered += 1
                Log.shared.info("Telegram: usage report sent on request" + (isOwner ? "" : " to \(peer.label)"))
            }
            return
        }
        // Someone else: an ignored one hears nothing; a new one waits for the owner.
        if viewers.status(of: peer.id) == .ignored { return }
        let askOwner = viewers.request(from: peer, now: now)
        onViewers()
        if askOwner {
            Log.shared.info("Telegram: \(peer.label) asked to see usage reports")
            let who = "<b>\(UsageText.html(peer.name))</b>" + (peer.username.map { " (@\(UsageText.html($0)))" } ?? "")
            await send("👋 \(who) wants to see AI usage from this bot.", to: settings.chatId,
                       markup: .viewerRequest(chatId: peer.id), client: client)
            await send("👋 I've asked \(UsageText.html(ownerName)) to let you see AI usage. You'll get it here once they allow it.",
                       to: peer.id, markup: nil, client: client)
            lastWaitNote[peer.id] = now
        } else if lastWaitNote[peer.id].map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            lastWaitNote[peer.id] = now
            await send("⏳ Still waiting for \(UsageText.html(ownerName)) to allow you.", to: peer.id, markup: nil, client: client)
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
