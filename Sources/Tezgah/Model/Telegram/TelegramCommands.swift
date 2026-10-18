import Foundation

/// What can be done from Telegram: the same things the boards do, by command or button. Buttons
/// carry a letter and the first 8 characters of a card's id ("o:1a2b3c4d").
extension TelegramBot {
    static let commandList = [
        ("durum", "Seçili projenin panosu"),
        ("kartlar", "Kartlar ve düğmeleri"),
        ("kart", "Yapılacak'a kart ekle: /kart Başlık"),
        ("sira", "Sırayı başlat ya da durdur"),
        ("projeler", "Projeler ve seçim"),
        ("yardim", "Komutlar"),
    ]

    static let help = """
        Komutlar:
        /durum — seçili projenin panosu
        /kartlar — kartlar; her birini orkestrayla başlat, koşusuna bak, durdur
        /kart Başlık — Yapılacak'a kart ekler; alt satırlar kartın notu olur
        /sira — sırayı başlat ya da durdur
        /projeler — projeler; birine dokununca o seçilir
        /proje ad — projeyi adıyla seç

        Planlayıcı soru sorarsa o mesajı yanıtla: cevabın kartın notuna eklenir, kart baştan başlar.
        """

    // MARK: Commands

    func command(_ text: String) async {
        guard let store else { return }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let rest = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        let words = firstLine.split(separator: " ", maxSplits: 1).map(String.init)
        // "/kart@tezgah_bot Başlık" in groups; the bot's name goes.
        let name = (words.first ?? "").lowercased().split(separator: "@").first.map(String.init) ?? ""
        let argument = words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""

        switch name {
        case "/start", "/yardim", "/help":
            await send(Self.help)
        case "/projeler":
            await sendProjects(store)
        case "/proje":
            guard let project = Self.project(named: argument, in: store.projects) else {
                await send("“\(argument)” adında bir proje yok. /projeler ile listeye bak.")
                return
            }
            projectPath = project.url.path
            await send(Self.status(of: project, store: store))
        case "/durum":
            if let project = currentProject(store) {
                await send(Self.status(of: project, store: store), buttons: [[Button(title: "Kartlar", data: "k"), Button(title: "Sıra", data: "q")]])
            } else {
                await sendProjects(store)
            }
        case "/kartlar":
            await sendCards(store)
        case "/kart":
            guard let project = currentProject(store) else { return await sendProjects(store) }
            guard let card = project.board.add(argument, notes: rest.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                await send("Başlık yaz: /kart Başlık (alt satırlar kartın notu olur)")
                return
            }
            await send("“\(card.title)” \(project.name) panosunda Yapılacak'a eklendi.",
                       buttons: [[Button(title: "Orkestrayla Başlat", data: "o:\(Self.short(card.id))"), Button(title: "Kartlar", data: "k")]])
        case "/sira":
            guard let project = currentProject(store) else { return await sendProjects(store) }
            await sendQueue(of: project)
        default:
            await send("Bunu anlamadım.\n\n" + Self.help)
        }
    }

    /// A button pressed; the answer shows as a short note on the phone.
    func button(_ data: String, message: Int?) async -> String? {
        let parts = data.split(separator: ":").map(String.init)
        guard let kind = parts.first else { return nil }
        let key = parts.count > 1 ? parts[1] : ""

        // An approval needs nothing but its waiting question.
        if kind == "a" {
            guard let approval = approvals[key] else { return "Bu onay artık geçerli değil" }
            let yes = parts.count > 2 && parts[2] == "1"
            approval.answer(yes)
            return yes ? "Çalıştırılıyor" : "Reddedildi"
        }
        if kind == "n" { // "Vazgeç"
            if let message { await update(message, text: "Vazgeçildi.") }
            return nil
        }
        guard let store else { return nil }

        switch kind {
        case "p": // pick a project
            guard let project = store.projects.first(where: { Self.short($0.url.path) == key }) else { return "Proje bulunamadı" }
            projectPath = project.url.path
            await send(Self.status(of: project, store: store), buttons: [[Button(title: "Kartlar", data: "k"), Button(title: "Sıra", data: "q")]])
            return project.name
        case "k":
            await sendCards(store)
            return nil
        case "q":
            guard let project = currentProject(store) else { return nil }
            await sendQueue(of: project)
            return nil
        case "qs", "qx": // start or stop the queue
            guard let project = store.projects.first(where: { Self.short($0.url.path) == key }) else { return "Proje bulunamadı" }
            if kind == "qs" {
                guard project.git.isRepository, OrchestraQueue.nextCard(on: project.board) != nil else { return "Sırada kart yok" }
                store.startQueue(in: project)
            } else {
                store.stopQueue(in: project)
            }
            await sendQueue(of: project)
            return kind == "qs" ? "Sıra başladı" : "Sıra durdu"
        case "pm": // an agent's permission
            guard parts.count > 3, let request = Int(parts[2]), let answer = Notifier.Answer(rawValue: parts[3]),
                  let tab = store.projects.lazy.flatMap(\.terminals).first(where: { Self.short($0.id) == key })?.id else { return "Oturum bulunamadı" }
            let answered = store.answerPermission(tab: tab, request: request, answer: answer)
            if let message { await update(message, text: "Onay yanıtlandı: " + (answer == .deny ? "Reddedildi" : "İzin verildi")) }
            return answered ? nil : "Bu istek artık geçerli değil"
        default:
            break
        }

        // The rest are about a card.
        guard let (card, project) = Self.card(key, in: store.projects) else { return "Kart bulunamadı" }
        switch kind {
        case "o": // start with the orchestra
            if store.orchestraRuns[card.id]?.isActive == true { return "Zaten çalışıyor" }
            guard card.worktree == nil else { return "Kartın zaten bir dalı var; önce baştan başlat" }
            guard project.git.isRepository else { return "Proje bir git deposu değil" }
            store.startOrchestra(card, in: project, inBackground: true)
            await send("“\(card.title)” orkestrayla başladı.", buttons: [[Button(title: "Koşuyu Göster", data: "r:\(key)")]])
            return "Başladı"
        case "r": // the run's page, in short
            await sendRun(card, project, store: store)
            return nil
        case "x": // stop
            guard store.orchestraRuns[card.id] != nil else { return "Çalışan bir koşu yok" }
            store.stopOrchestra(of: card, in: project)
            return "Durduruldu"
        case "c": // go on after a limit, on the same branch
            return await store.continueOrchestra(of: card.id, in: project) ? "Devam ediyor" : "Bu kart devam ettirilemiyor"
        case "b": // start over, asked first when the branch has work
            if await store.hasWork(on: card, in: project) {
                await send("“\(card.title)” baştan başlatılırsa “\(card.worktree?.branch ?? "")” dalındaki iş silinir. Emin misin?",
                           buttons: [[Button(title: "Evet, baştan başlat", data: "B:\(key)"), Button(title: "Vazgeç", data: "n")]])
                return nil
            }
            return await store.restartOrchestra(of: card.id, in: project, confirmed: true) ? "Baştan başladı" : "Başlatılamadı"
        case "B":
            if let message { await update(message, text: "“\(card.title)” baştan başlatılıyor.") }
            return await store.restartOrchestra(of: card.id, in: project, confirmed: true) ? "Baştan başladı" : "Başlatılamadı"
        default:
            return nil
        }
    }

    /// A reply to a message with a card's questions.
    func answerQuestions(of cardID: UUID, with answer: String) async {
        guard let store, let project = store.projects.first(where: { $0.board.cards.contains { $0.id == cardID } }),
              let card = project.board.cards.first(where: { $0.id == cardID }) else { return }
        guard !answer.isEmpty else { return }
        let restarted = await store.restartOrchestra(of: cardID, in: project, answer: answer, confirmed: true)
        await send(restarted ? "Cevabın “\(card.title)” kartının notuna eklendi; kart baştan başlıyor." : "Kart şu an baştan başlatılamadı; Tezgah'tan bak.")
    }

    // MARK: Messages

    private func currentProject(_ store: WorkspaceStore) -> Project? {
        if let path = projectPath, let project = store.projects.first(where: { $0.url.path == path }) { return project }
        return store.projects.count == 1 ? store.projects.first : nil
    }

    private func sendProjects(_ store: WorkspaceStore) async {
        guard !store.projects.isEmpty else { await send("Tezgah'ta proje yok."); return }
        let lines = store.projects.map { project in
            let doing = project.board.cards(in: .doing).count
            let todo = project.board.cards(in: .todo).count
            return "\(project.name): \(todo) yapılacak, \(doing) yapılıyor" + (project.orchestraQueue != nil ? " · sıra açık" : "")
        }
        let buttons = store.projects.map { [Button(title: $0.name, data: "p:\(Self.short($0.url.path))")] }
        await send("Projeler (birini seç):\n\n" + lines.joined(separator: "\n"), buttons: buttons)
    }

    private func sendCards(_ store: WorkspaceStore) async {
        guard let project = currentProject(store) else { return await sendProjects(store) }
        let cards = project.board.cards(in: .doing) + project.board.cards(in: .todo)
        guard !cards.isEmpty else { await send("\(project.name): açık kart yok. /kart Başlık ile ekle."); return }
        var lines = ["\(project.name) · kartlar:"]
        var buttons: [[Button]] = []
        for (index, card) in cards.prefix(20).enumerated() {
            let number = index + 1
            lines.append("\(number). \(card.title) — \(Self.state(of: card, store: store))")
            let key = Self.short(card.id)
            var row: [Button] = []
            if store.orchestraRuns[card.id]?.isActive == true {
                row.append(Button(title: "\(number) Koşu", data: "r:\(key)"))
                row.append(Button(title: "\(number) Durdur", data: "x:\(key)"))
            } else if card.run?.stopReason != nil {
                row.append(Button(title: "\(number) Koşu", data: "r:\(key)"))
                if store.continueTitle(for: card.id) != nil { row.append(Button(title: "\(number) Devam", data: "c:\(key)")) }
                row.append(Button(title: "\(number) Baştan", data: "b:\(key)"))
            } else if card.worktree == nil {
                row.append(Button(title: "\(number) Başlat", data: "o:\(key)"))
            }
            if !row.isEmpty { buttons.append(row) }
        }
        if cards.count > 20 { lines.append("… ve \(cards.count - 20) kart daha") }
        await send(lines.joined(separator: "\n"), buttons: buttons)
    }

    private func sendQueue(of project: Project) async {
        let waiting = project.board.cards(in: .todo).filter { $0.worktree == nil }.count
        let key = Self.short(project.url.path)
        if project.orchestraQueue != nil {
            await send("\(project.name) · sıra açık, \(waiting) kart bekliyor.", buttons: [[Button(title: "Sırayı Durdur", data: "qx:\(key)")]])
        } else {
            await send("\(project.name) · sıra kapalı, Yapılacak'ta \(waiting) kart var.", buttons: [[Button(title: "Sırayı Başlat", data: "qs:\(key)")]])
        }
    }

    private func sendRun(_ card: BoardCard, _ project: Project, store: WorkspaceStore) async {
        var text = Self.run(of: card, store: store)
        let key = Self.short(card.id)
        var buttons: [[Button]] = []
        if store.orchestraRuns[card.id]?.isActive == true {
            buttons = [[Button(title: "Durdur", data: "x:\(key)")]]
        } else if card.run?.isWaitingForAnswers == true {
            text += "\n\nBu mesajı yanıtlayarak cevap yaz; kart baştan başlar."
        } else if card.run?.stopReason != nil {
            var row: [Button] = []
            if let title = store.continueTitle(for: card.id) { row.append(Button(title: title, data: "c:\(key)")) }
            row.append(Button(title: "Baştan Başlat", data: "b:\(key)"))
            buttons = [row]
        }
        let message = await send(text, buttons: buttons)
        if card.run?.isWaitingForAnswers == true, let message { questionMessages[message] = card.id }
    }

    // MARK: Text

    /// A board in a few lines: the queue, what runs where, what waits.
    static func status(of project: Project, store: WorkspaceStore) -> String {
        var lines = [project.name]
        let waiting = project.board.cards(in: .todo).filter { $0.worktree == nil }
        lines.append(project.orchestraQueue != nil ? "Sıra açık · \(waiting.count) kart bekliyor" : "Sıra kapalı")
        let doing = project.board.cards(in: .doing)
        if !doing.isEmpty {
            lines.append("")
            lines.append("Yapılıyor:")
            lines += doing.map { "• \($0.title) — \(state(of: $0, store: store))" }
        }
        let todo = project.board.cards(in: .todo)
        if !todo.isEmpty {
            lines.append("")
            lines.append("Yapılacak (\(todo.count)):")
            lines += todo.prefix(8).map { "• \($0.title)" }
            if todo.count > 8 { lines.append("• … \(todo.count - 8) kart daha") }
        }
        let today = project.board.cards(in: .done).filter { $0.completedAt.map(Calendar.current.isDateInToday) == true }
        if !today.isEmpty {
            lines.append("")
            lines.append("Bugün biten: \(today.count)")
        }
        return lines.joined(separator: "\n")
    }

    /// Where a card is, in words.
    static func state(of card: BoardCard, store: WorkspaceStore) -> String {
        if let run = store.orchestraRuns[card.id], run.isActive { return run.summary }
        if let record = card.run {
            if record.isWaitingForAnswers { return "bilgi bekliyor" }
            if let reason = record.stopReason { return "takıldı: \(reason)" }
            if record.isMerged { return "birleştirildi" }
        }
        if card.worktree != nil { return "kendi dalında" }
        return card.column == .todo ? "bekliyor" : card.column.title.lowercased(with: Locale(identifier: "tr"))
    }

    /// The run page in short: where it is, the agents, the last steps, the questions.
    static func run(of card: BoardCard, store: WorkspaceStore) -> String {
        var lines = [card.title, "Durum: \(state(of: card, store: store))"]
        if let run = store.orchestraRuns[card.id], run.isActive {
            var agents: [(UUID?, String)] = [(run.plannerTab, "Planlayıcı"), (run.developerTab, "Geliştirici")]
            agents += run.reviewers.keys.map { ($0, "Gözden geçiren") }
            agents.append((run.judgeTab, "Karar verici"))
            let live = agents.compactMap { tab, role -> String? in
                guard let tab, let activity = store.claudeTab(tab)?.session.agent else { return nil }
                let doing = activity.state == .working ? (activity.currentStep.map { "çalışıyor — \($0)" } ?? "çalışıyor") : stateName(activity.state)
                return "• \(store.agentRole(tab, in: run) ?? role): \(doing)"
            }
            if !live.isEmpty { lines += ["", "Ajanlar:"] + live }
        }
        if let record = card.run {
            if record.isWaitingForAnswers, let questions = record.plan?.questions, !questions.isEmpty {
                lines += ["", "Planlayıcının soruları:"] + questions.enumerated().map { "\($0.offset + 1). \($0.element)" }
            }
            let steps = record.events.suffix(6).map { event in
                event.date.formatted(date: .omitted, time: .shortened) + " " + event.text
            }
            if !steps.isEmpty { lines += ["", "Son adımlar:"] + steps }
        }
        return lines.joined(separator: "\n")
    }

    private static func stateName(_ state: AgentActivity.State) -> String {
        switch state {
        case .starting: "başlıyor"
        case .idle: "hazır"
        case .working: "çalışıyor"
        case .needsPermission: "onay bekliyor"
        case .finished: "turu bitti"
        case .ended: "kapandı"
        }
    }

    // MARK: Lookups

    static func short(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a: the same key on every launch
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(String(hash, radix: 16).prefix(8))
    }

    static func card(_ key: String, in projects: [Project]) -> (BoardCard, Project)? {
        for project in projects {
            if let card = project.board.cards.first(where: { short($0.id) == key }) { return (card, project) }
        }
        return nil
    }

    static func project(named name: String, in projects: [Project]) -> Project? {
        let wanted = name.lowercased(with: Locale(identifier: "tr"))
        guard !wanted.isEmpty else { return nil }
        return projects.first { $0.name.lowercased(with: Locale(identifier: "tr")) == wanted }
            ?? projects.first { $0.name.lowercased(with: Locale(identifier: "tr")).contains(wanted) }
    }
}
