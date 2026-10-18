import Foundation
import Testing
@testable import Tezgah

/// Telegram stand-in: answers the calls and keeps the messages sent.
actor FakeTelegram: TelegramTransport {
    private(set) var sent: [(chat: Int64, text: String, buttons: [String])] = []
    private(set) var methods: [String] = []
    private var nextMessage = 100

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        methods.append(method)
        switch method {
        case "getMe":
            return ["username": "tezgah_test_bot"]
        case "getUpdates":
            try await Task.sleep(for: .seconds(3600)) // the tests hand updates in themselves
            return []
        case "sendMessage":
            let keyboard = (parameters["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: Any]]] ?? []
            sent.append(((parameters["chat_id"] as? Int64) ?? 0, parameters["text"] as? String ?? "", keyboard.flatMap { $0 }.compactMap { $0["callback_data"] as? String }))
            nextMessage += 1
            return ["message_id": nextMessage]
        default:
            return true
        }
    }
}

@MainActor
@Suite struct TelegramTests {
    private func message(_ text: String, from chat: Int64, replyTo: Int? = nil) -> [String: Any] {
        var message: [String: Any] = ["chat": ["id": chat], "from": ["id": chat, "first_name": "Ahmet"], "text": text]
        if let replyTo { message["reply_to_message"] = ["message_id": replyTo] }
        return ["update_id": 1, "message": message]
    }

    private func button(_ data: String, from user: Int64) -> [String: Any] {
        ["update_id": 2, "callback_query": ["id": "q", "from": ["id": user], "data": data, "message": ["message_id": 7]]]
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func makeBot() -> (TelegramBot, FakeTelegram) {
        let bot = TelegramBot(defaults: UserDefaults(suiteName: "tezgah-telegram-\(UUID().uuidString)")!)
        let fake = FakeTelegram()
        bot.connect(using: fake)
        return (bot, fake)
    }

    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    @Test func onlyTheChatThatSentTheCodeIsListenedTo() async throws {
        let (bot, fake) = makeBot()
        defer { bot.disconnect(forgetting: false) }
        try await waitUntil { if case .pairing = bot.state { true } else { false } }
        guard case .pairing(let code, let name) = bot.state else { return }
        #expect(name == "@tezgah_test_bot" && code.count == 6)

        await bot.handle(message("123", from: 42)) // a wrong code is not answered
        #expect(bot.chatID == nil)
        await bot.handle(message(code, from: 42))
        #expect(bot.chatID == 42 && bot.isPaired)
        #expect(await fake.methods.contains("setMyCommands"))
        #expect(await fake.sent.last?.text.hasPrefix("Eşleşti") == true)

        let before = await fake.sent.count
        await bot.handle(message("/durum", from: 99)) // a stranger
        await bot.handle(button("k", from: 99))
        #expect(await fake.sent.count == before)
    }

    @Test func cardsAreAddedAndTheBoardIsTold() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let (bot, fake) = makeBot()
        defer { bot.disconnect(forgetting: false) }
        bot.store = store
        bot.chatID = 42

        await bot.handle(message("/kart Ödeme ekranı\nKartla ödeme olsun", from: 42))
        let card = try #require(project.board.cards(in: .todo).first)
        #expect(card.title == "Ödeme ekranı" && card.notes == "Kartla ödeme olsun")
        #expect(await fake.sent.last?.buttons.contains("o:\(TelegramBot.short(card.id))") == true)

        await bot.handle(message("/durum", from: 42))
        let status = try #require(await fake.sent.last?.text)
        #expect(status.contains(project.name) && status.contains("Sıra kapalı") && status.contains("Yapılacak (1):\n• Ödeme ekranı"))

        await bot.handle(message("/kartlar", from: 42))
        #expect(await fake.sent.last?.text.contains("1. Ödeme ekranı — bekliyor") == true)

        await bot.handle(message("/sira", from: 42))
        #expect(await fake.sent.last?.buttons == ["qs:\(TelegramBot.short(project.url.path))"])
        await bot.handle(message("/bilinmeyen", from: 42))
        #expect(await fake.sent.last?.text.hasPrefix("Bunu anlamadım") == true)
    }

    @Test func approvalsCanBeAnsweredFromThePhone() async throws {
        let (bot, fake) = makeBot()
        defer { bot.disconnect(forgetting: false) }
        try await waitUntil { if case .pairing = bot.state { true } else { false } }
        guard case .pairing(let code, _) = bot.state else { return }
        await bot.handle(message(code, from: 42))

        var answer: Bool?
        let id = UUID()
        bot.askApproval(id: id, text: "Geliştirici veritabanını değiştirmek istiyor") { answer = $0 }
        try await waitUntil { bot.approvals[TelegramBot.short(id)]?.message != nil }
        #expect(await fake.sent.last?.buttons == ["a:\(TelegramBot.short(id)):1", "a:\(TelegramBot.short(id)):0"])
        await bot.handle(button("a:\(TelegramBot.short(id)):1", from: 42))
        #expect(answer == true)
        bot.approvalSettled(id: id, approved: true)
        #expect(bot.approvals.isEmpty)
    }

    @Test func aReplyAnswersTheCardsQuestions() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let (bot, fake) = makeBot()
        defer { bot.disconnect(forgetting: false) }
        bot.store = store
        bot.chatID = 42
        let busy = try #require(project.board.add("Çalışan"))
        let card = try #require(project.board.add("Ödeme"))
        project.board.beginRun(on: card.id, team: OrchestraTeam(), branch: "tezgah/odeme")
        project.board.logRun(on: card.id, BoardCard.RunEvent(kind: .blocked, text: "Bilgi gerekiyor"))
        store.orchestraRuns[busy.id] = OrchestraRun(cardID: busy.id, team: OrchestraTeam(), branch: "b", worktree: base, directory: base, base: "a")
        project.orchestraQueue = OrchestraQueue(cardID: busy.id) // busy: the answered card waits its turn

        bot.questionMessages[555] = card.id
        await bot.handle(message("iyzico kullanılacak", from: 42, replyTo: 555))
        #expect(project.board.cards.first { $0.id == card.id }?.notes == "Planlayıcının sorularına cevap:\niyzico kullanılacak")
        #expect(await fake.sent.last?.text.contains("baştan başlıyor") == true)
    }

    @Test func keysStayTheSameAndMessagesFit() {
        #expect(TelegramBot.short("/Users/a/beecons") == TelegramBot.short("/Users/a/beecons"))
        #expect(TelegramBot.short("/Users/a/beecons") != TelegramBot.short("/Users/a/testlab"))
        #expect(TelegramBot.fit(String(repeating: "a", count: 5000)).count < 4096)
        let keyboard = TelegramBot.keyboard([[TelegramBot.Button(title: "x", data: String(repeating: "d", count: 100))]])
        let data = ((keyboard["inline_keyboard"] as? [[[String: Any]]])?.first?.first?["callback_data"] as? String) ?? ""
        #expect(data.count == 64)
    }
}
