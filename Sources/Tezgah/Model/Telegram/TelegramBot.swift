import AppKit
import Observation

/// Tezgah on Telegram: the orchestra's news, its questions and approvals, and commands to look at
/// and drive the boards, from the phone.
///
/// It reads the bot by long polling (`getUpdates`): Tezgah asks Telegram for new messages, so no
/// server and no open port are needed, only the Mac awake with Tezgah running. It listens to one
/// chat only, the one that sent the pairing code shown in Ayarlar; anyone else gets no answer.
@MainActor
@Observable
final class TelegramBot {
    enum State: Equatable {
        case off
        case connecting
        /// Waiting for someone to send the bot this code.
        case pairing(code: String, bot: String)
        case paired(chat: String, bot: String)
        case failed(String)
    }

    struct Button {
        let title: String
        let data: String
    }

    private(set) var state = State.off
    @ObservationIgnored weak var store: WorkspaceStore?
    @ObservationIgnored private var transport: (any TelegramTransport)?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var botName = ""
    @ObservationIgnored private var pairingCode = ""
    /// Messages that asked a card's questions: a reply to one answers them.
    @ObservationIgnored var questionMessages: [Int: UUID] = [:]
    /// The last permission request told for each agent tab, so each is told once.
    @ObservationIgnored var announcedRequests: [UUID: Int] = [:]
    /// Approvals waiting on a button: who to tell, and the message to update.
    @ObservationIgnored var approvals: [String: (answer: (Bool) -> Void, message: Int?, text: String)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Pairing

    /// The paired chat, kept across launches.
    var chatID: Int64? {
        get { (defaults.object(forKey: "telegramChatID") as? NSNumber)?.int64Value }
        set {
            if let newValue { defaults.set(NSNumber(value: newValue), forKey: "telegramChatID") } else { defaults.removeObject(forKey: "telegramChatID") }
        }
    }

    private var chatName: String {
        get { defaults.string(forKey: "telegramChatName") ?? "" }
        set { defaults.set(newValue, forKey: "telegramChatName") }
    }

    /// The project commands act on, by path.
    var projectPath: String? {
        get { defaults.string(forKey: "telegramProject") }
        set { defaults.set(newValue, forKey: "telegramProject") }
    }

    var isPaired: Bool {
        if case .paired = state { true } else { false }
    }

    /// At launch: goes on with a token saved before.
    func resume() {
        guard state == .off, let token = TelegramToken.read() else { return }
        connect(using: TelegramHTTP(token: token))
    }

    /// After a failure: tries the saved token again.
    func retry() {
        guard let token = TelegramToken.read() else { return }
        connect(using: TelegramHTTP(token: token))
    }

    /// A new token from Ayarlar.
    func connect(token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        TelegramToken.save(token)
        disconnect(forgetting: false)
        chatID = nil
        connect(using: TelegramHTTP(token: token))
    }

    /// `transport` stands in for Telegram in tests.
    func connect(using transport: any TelegramTransport) {
        self.transport = transport
        state = .connecting
        poller = Task { [weak self] in
            guard let self else { return }
            do {
                let me = try await transport.call("getMe", [:]) as? [String: Any]
                botName = (me?["username"] as? String).map { "@\($0)" } ?? "bot"
            } catch {
                fail(error)
                return
            }
            if chatID == nil {
                startPairing()
            } else {
                state = .paired(chat: chatName, bot: botName)
                updateAwake()
            }
            await poll()
        }
    }

    /// Forgets the chat; a new code pairs another (or the same) one.
    func unpair() {
        chatID = nil
        chatName = ""
        questionMessages = [:]
        if transport != nil { startPairing() }
    }

    /// Stops listening; `forgetting` also removes the token and the pairing.
    func disconnect(forgetting: Bool = true) {
        poller?.cancel()
        poller = nil
        transport = nil
        if forgetting {
            TelegramToken.save(nil)
            chatID = nil
            chatName = ""
        }
        state = .off
        updateAwake()
    }

    private func startPairing() {
        pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
        state = .pairing(code: pairingCode, bot: botName)
        updateAwake()
    }

    private func fail(_ error: Error) {
        let reason = switch (error as? TelegramError)?.code {
        case 401: "Bot token'ı geçersiz. BotFather'dan aldığın token'ı yeniden yapıştır."
        case 409: "Bu bot başka bir yerde de dinleniyor (başka bir Tezgah ya da program). Orayı kapatıp yeniden bağlan."
        default: error.localizedDescription
        }
        poller?.cancel()
        poller = nil
        state = .failed(reason)
        updateAwake()
    }

    /// While paired, the Mac stays awake if the user wants: asleep, it hears nothing.
    func updateAwake() {
        let wanted = isPaired && AppSettings.shared.telegramKeepsAwake
        if wanted, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Telegram botu dinleniyor")
        } else if !wanted, let activity = awake {
            ProcessInfo.processInfo.endActivity(activity)
            awake = nil
        }
    }

    // MARK: Polling

    private func poll() async {
        var delay: UInt64 = 2
        while !Task.isCancelled, let transport {
            do {
                let updates = try await transport.call("getUpdates", [
                    "offset": offset, "timeout": 50, "allowed_updates": ["message", "callback_query"],
                ]) as? [[String: Any]] ?? []
                delay = 2
                for update in updates {
                    if let id = update["update_id"] as? Int { offset = max(offset, id + 1) }
                    await handle(update)
                }
            } catch is CancellationError {
                return
            } catch let error as TelegramError where error.code == 401 || error.code == 409 {
                fail(error)
                return
            } catch {
                // No network for a while (the Mac woke up, Wi-Fi changed): try again, more slowly.
                try? await Task.sleep(for: .seconds(Double(delay)))
                delay = min(delay * 2, 60)
            }
        }
    }

    /// One update from Telegram; only the paired chat (or, before pairing, its code) gets through.
    func handle(_ update: [String: Any]) async {
        if let message = update["message"] as? [String: Any] {
            guard let chat = message["chat"] as? [String: Any], let chat = (chat["id"] as? NSNumber)?.int64Value else { return }
            let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let paired = chatID else {
                if case .pairing = state, text == pairingCode { await pair(with: chat, message: message) }
                return
            }
            guard chat == paired else { return }
            if let replied = (message["reply_to_message"] as? [String: Any])?["message_id"] as? Int, let card = questionMessages[replied] {
                await answerQuestions(of: card, with: text)
            } else {
                await command(text)
            }
        } else if let query = update["callback_query"] as? [String: Any] {
            let from = ((query["from"] as? [String: Any])?["id"] as? NSNumber)?.int64Value
            guard let id = query["id"] as? String else { return }
            guard let paired = chatID, from == paired, let data = query["data"] as? String else {
                _ = try? await transport?.call("answerCallbackQuery", ["callback_query_id": id])
                return
            }
            let message = (query["message"] as? [String: Any])?["message_id"] as? Int
            let note = await button(data, message: message)
            _ = try? await transport?.call("answerCallbackQuery", ["callback_query_id": id, "text": note ?? ""])
        }
    }

    private func pair(with chat: Int64, message: [String: Any]) async {
        let from = message["from"] as? [String: Any]
        chatID = chat
        chatName = (from?["username"] as? String).map { "@\($0)" } ?? from?["first_name"] as? String ?? "Telegram"
        state = .paired(chat: chatName, bot: botName)
        updateAwake()
        _ = try? await transport?.call("setMyCommands", ["commands": Self.commandList.map { ["command": $0.0, "description": $0.1] }])
        await send("Eşleşti. Tezgah artık bu sohbeti dinliyor.\n\n" + Self.help)
    }

    // MARK: Sending

    /// Sends to the paired chat; the message's id, to reply to or update it later.
    @discardableResult
    func send(_ text: String, buttons: [[Button]] = []) async -> Int? {
        guard let chatID, let transport else { return nil }
        var parameters: [String: Any] = ["chat_id": chatID, "text": Self.fit(text), "disable_web_page_preview": true]
        if !buttons.isEmpty { parameters["reply_markup"] = Self.keyboard(buttons) }
        let message = try? await transport.call("sendMessage", parameters) as? [String: Any]
        return message?["message_id"] as? Int
    }

    /// Replaces a message's text and its buttons (none: they go).
    func update(_ message: Int, text: String, buttons: [[Button]] = []) async {
        guard let chatID, let transport else { return }
        _ = try? await transport.call("editMessageText", [
            "chat_id": chatID, "message_id": message, "text": Self.fit(text), "reply_markup": Self.keyboard(buttons),
        ])
    }

    static func keyboard(_ buttons: [[Button]]) -> [String: Any] {
        ["inline_keyboard": buttons.map { row in row.map { ["text": $0.title, "callback_data": String($0.data.prefix(64))] } }]
    }

    /// Telegram takes 4096 characters.
    static func fit(_ text: String) -> String {
        text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
    }

    // MARK: Approvals

    /// Puts an approval on the phone as well; `answer` gets the button pressed there.
    func askApproval(id: UUID, text: String, answer: @escaping (Bool) -> Void) {
        guard isPaired else { return }
        let key = Self.short(id)
        approvals[key] = (answer, nil, text)
        Task {
            let message = await send(text, buttons: [[Button(title: "Çalıştır", data: "a:\(key):1"), Button(title: "Reddet", data: "a:\(key):0")]])
            if approvals[key] != nil { approvals[key]?.message = message }
        }
    }

    /// The approval got its answer on the Mac (or from here): the phone's buttons go.
    func approvalSettled(id: UUID, approved: Bool) {
        guard let approval = approvals.removeValue(forKey: Self.short(id)), let message = approval.message else { return }
        Task { await update(message, text: approval.text + "\n\n→ " + (approved ? "Çalıştırıldı" : "Reddedildi")) }
    }

    static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}
