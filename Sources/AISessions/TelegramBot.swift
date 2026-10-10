import AISessionsCore
import Foundation

/// The listening side of the Telegram connection: "📊 Usage" (the button
/// kept under the chat), /usage, /start and the "📊 Usage now" button under
/// an alert each get a usage report back. Only the connected private chat is
/// answered. Long-polls getUpdates while Telegram is connected and stops for
/// the setup flow, which reads the same updates (Telegram allows one reader).
@MainActor
final class TelegramBot {
    /// Builds the reply: a report after a fresh reading if it can, else why
    /// there is none.
    var report: @MainActor () async -> String = { "📊 No usage reading yet." }
    /// Called with why the bot stopped listening, or nil once it listens.
    var onProblem: (String?) -> Void = { _ in }

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
    private var lastReport: Date?
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
                    guard let request = TelegramRequest.parse(update, chatId: settings.chatId,
                                                              bot: settings.botUsername, now: clock()) else { continue }
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

    /// One report per request, at most one per `minGap`.
    private func answer(_ request: TelegramRequest, client: TelegramClient, settings: TelegramSettings) async {
        let now = clock()
        let tooSoon = lastReport.map { now.timeIntervalSince($0) < Self.minGap } ?? false
        if case .reportFromButton(let id) = request {
            do {
                try await client.answerCallback(id, text: tooSoon ? "Just sent" : "Checking usage…")
            } catch {
                // Too old to answer (tapped while the Mac slept): no late report either.
                Log.shared.info("Telegram: a Usage tap was too old to answer (\(TelegramError.from(error).message))")
                return
            }
        }
        guard !tooSoon else { return }
        lastReport = now
        let html = await report()
        do {
            try await client.send(html: html, to: settings.chatId, markup: .usageKeyboard)
            answered += 1
            Log.shared.info("Telegram: usage report sent on request")
        } catch {
            Log.shared.warn("Telegram: usage report NOT sent: \(TelegramError.from(error).message)")
        }
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
