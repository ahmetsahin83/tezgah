import Foundation

/// What Tezgah tells the user away from the Mac (Telegram), next to its notifications: the
/// orchestra's merges, stops and questions, the queue, and agents waiting for permission.
extension WorkspaceStore {
    func announceStop(of card: BoardCard, reason: String, needsAnswers: Bool, in project: Project) {
        guard telegram.isPaired else { return }
        let key = TelegramBot.short(card.id)
        Task {
            if needsAnswers {
                let questions = card.run?.plan?.questions ?? project.board.cards.first { $0.id == card.id }?.run?.plan?.questions ?? []
                var text = "\(project.name) · Bilgi gerekiyor\n“\(card.title)”\n\n\(reason)"
                if !questions.isEmpty { text += "\n\n" + questions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") }
                text += "\n\nBu mesajı yanıtlayarak cevap yaz; cevabın kartın notuna eklenir, kart baştan başlar."
                if let message = await telegram.send(text, buttons: [[TelegramBot.Button(title: "Koşuyu Göster", data: "r:\(key)")]]) {
                    telegram.questionMessages[message] = card.id
                }
            } else {
                var row = [TelegramBot.Button(title: "Koşuyu Göster", data: "r:\(key)")]
                if let title = continueTitle(for: card.id) { row.append(TelegramBot.Button(title: title, data: "c:\(key)")) }
                row.append(TelegramBot.Button(title: "Baştan Başlat", data: "b:\(key)"))
                await telegram.send("\(project.name) · Takıldı\n“\(card.title)”\n\n\(reason)", buttons: [row])
            }
        }
    }

    func announceMerge(of card: BoardCard, rounds: Int, pushed: Bool?, in project: Project) {
        guard telegram.isPaired else { return }
        var text = "\(project.name) · Birleştirildi\n“\(card.title)” · \(rounds) tur"
        if let branch = project.git.status.branch { text += " → \(branch)" }
        if let pushed { text += pushed ? "\nPush'landı." : "\nPush edilemedi; birleştirme Mac'te duruyor." }
        Task { await telegram.send(text, buttons: [[TelegramBot.Button(title: "Koşuyu Göster", data: "r:\(TelegramBot.short(card.id))")]]) }
    }

    func announceQueue(_ text: String, in project: Project) {
        guard telegram.isPaired else { return }
        Task { await telegram.send(text) }
    }

    /// An agent at its usage limit, and when it goes on.
    func announceLimit(_ session: TerminalSession, project: Project, line: String?, resumeAt: Date) {
        guard telegram.isPaired, let agent = session.agent else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr")
        formatter.dateFormat = Calendar.current.isDate(resumeAt, inSameDayAs: .now) ? "HH:mm" : "d MMMM HH:mm"
        var text = "\(project.name) · Limit doldu\n\(agentTitle(agent, in: session))"
        if let line { text += "\n\n\(line.trimmingCharacters(in: .whitespaces))" }
        text += "\n\n\(formatter.string(from: resumeAt)) civarında kendiliğinden devam edecek."
        Task { await telegram.send(text) }
    }

    func announceLimitResume(_ session: TerminalSession, project: Project) {
        guard telegram.isPaired, let agent = session.agent else { return }
        Task { await telegram.send("\(project.name) · Devam ediyor\n\(agentTitle(agent, in: session))\n\nLimit sıfırlandı, kaldığı yerden devam etmesi söylendi.") }
    }

    private func agentTitle(_ agent: AgentActivity, in session: TerminalSession) -> String {
        orchestraRun(of: session.id).flatMap { agentRole(session.id, in: $0) } ?? "\(agent.provider.displayName) · \(session.title)"
    }

    /// An agent waiting for permission: plain ones are answered with buttons, a question or a plan
    /// needs Tezgah. Each request is told once.
    func announcePermission(_ activity: AgentActivity, in session: TerminalSession, project: Project) {
        guard telegram.isPaired, telegram.announcedRequests[session.id] != activity.requestSerial else { return }
        telegram.announcedRequests[session.id] = activity.requestSerial
        let who = agentTitle(activity, in: session)
        let text = "\(project.name) · Onay bekliyor\n\(who)\n\n\(activity.message ?? "Devam etmek için iznini istiyor.")"
        let key = "\(TelegramBot.short(session.id)):\(activity.requestSerial)"
        let buttons: [TelegramBot.Button] = switch Self.notificationCategory(for: activity) {
        case .permission: [.init(title: "İzin Ver", data: "pm:\(key):allow"), .init(title: "Reddet", data: "pm:\(key):deny")]
        case .permissionWithAlways: [
            .init(title: "İzin Ver", data: "pm:\(key):allow"), .init(title: "Bir Daha Sorma", data: "pm:\(key):always"),
            .init(title: "Reddet", data: "pm:\(key):deny"),
        ]
        case nil: []
        }
        Task { await telegram.send(buttons.isEmpty ? text + "\n\nBunu Tezgah'tan yanıtlaman gerekiyor." : text, buttons: buttons.isEmpty ? [] : [buttons]) }
    }
}
