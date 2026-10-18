import SwiftUI

/// One card's orchestra run on a page: the step it is at, what each agent is doing now, and
/// everything that happened so far. A finished card keeps its story here.
struct OrchestraRunView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let page: RunPage
    let project: Project
    /// Codex's model names come from Codex itself; drawn again once they are in.
    @State private var hasCodexModels = false

    var body: some View {
        let _ = hasCodexModels
        Group {
            if let card = page.card {
                content(card)
            } else {
                EmptyState(symbol: "person.3", title: "Kart silinmiş", message: "Bu koşunun kartı panoda artık yok.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: EditorThemes.theme(for: colorScheme).background))
        .task {
            _ = await AgentModels.codexModels()
            hasCodexModels = true
        }
    }

    private func content(_ card: BoardCard) -> some View {
        let run = store.orchestraRuns[card.id]
        let record = card.run
        return Group {
            if run == nil && record == nil {
                EmptyState(symbol: "person.3", title: "Bu kart orkestrayla yürütülmedi",
                           message: "Kartın menüsündeki “Orkestrayla Başlat” ile ekibe verebilirsin.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(card, run: run, record: record)
                        if let record, let reason = record.stopReason, run?.isActive != true {
                            StopPanel(
                                reason: reason, questions: record.isWaitingForAnswers ? record.plan?.questions ?? [] : nil,
                                continueTitle: store.continueTitle(for: card.id),
                                carryOn: { Task { await store.continueOrchestra(of: card.id, in: project) } },
                                restart: { answer in Task { await store.restartOrchestra(of: card.id, in: project, answer: answer) } }
                            )
                        }
                        stages(team: run?.team ?? record?.team ?? project.orchestraTeam, run: run, record: record)
                        agents(team: run?.team ?? record?.team ?? project.orchestraTeam, run: run, record: record)
                        if let plan = record?.plan, plan.blocked == nil {
                            PlanSection(plan: plan, planner: (run?.team ?? record?.team)?.planner) { idea in
                                _ = project.board.addIdea(idea.id, from: card.id)
                            }
                        } else if run?.phase == .planning {
                            Text("Planlayıcı kartı okuyup kodu tarıyor; plan hazır olunca burada görünecek ve geliştiriciye gidecek.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        timeline(record?.events ?? [])
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Header

    private func header(_ card: BoardCard, run: OrchestraRun?, record: BoardCard.RunRecord?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.system(size: 17, weight: .semibold))
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(facts(card, record: record, now: context.date).joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let tab = run?.developerTab, store.claudeTab(tab) != nil {
                Button {
                    store.focusTab(tab)
                } label: {
                    Label("Geliştirici", systemImage: "bubble.left.and.text.bubble.right")
                }
                .help("Geliştiricinin sohbetini aç")
            }
            if card.worktree != nil {
                Button {
                    store.showWorktree(of: card, in: project)
                } label: {
                    Label("Worktree", systemImage: "arrow.triangle.branch")
                }
                .help("Kartın worktree'sine git")
            }
            if run?.isActive == true {
                Button {
                    store.stopOrchestra(of: card, in: project)
                } label: {
                    Label("Durdur", systemImage: "stop.fill")
                }
                .help("Orkestrayı durdur; worktree ve geliştiricinin sekmesi kalır")
            }
        }
        .controlSize(.small)
    }

    /// Branch, commits, how long it took, what waits behind it.
    private func facts(_ card: BoardCard, record: BoardCard.RunRecord?, now: Date) -> [String] {
        var facts: [String] = []
        if let branch = record?.branch ?? card.worktree?.branch { facts.append(branch) }
        if let record {
            if record.commits > 0 { facts.append("\(record.commits) commit") }
            facts.append(Self.duration(from: record.startedAt, to: record.endedAt ?? now))
        }
        if project.orchestraQueue?.cardID == card.id {
            let waiting = project.board.cards(in: .todo).filter { $0.worktree == nil }.count
            facts.append(waiting == 0 ? "sıranın son kartı" : "sırada \(waiting) kart daha")
        }
        return facts
    }

    static func duration(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        if minutes < 1 { return "az önce başladı" }
        if minutes < 60 { return "\(minutes) dk" }
        return "\(minutes / 60) sa \(minutes % 60) dk"
    }

    // MARK: Stages

    private func stages(team: OrchestraTeam, run: OrchestraRun?, record: BoardCard.RunRecord?) -> some View {
        let stages = RunStage.stages(for: team)
        let current = run.flatMap { RunStage.current($0.phase) }
        let merged = record?.isMerged == true
        // A stopped run shows where it got to.
        let reached = current ?? (merged ? nil : RunStage.reached(record?.events ?? []))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(stages, id: \.self) { stage in
                    let state: StageState = merged ? .done
                        : stage == reached ? (current == nil ? .stopped : .current)
                        : reached.map { stage < $0 } == true ? .done : .upcoming
                    StageChip(stage: stage, state: state)
                }
            }
            if let run, run.isActive {
                Text(roundLine(run))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func roundLine(_ run: OrchestraRun) -> String {
        var line = "Tur \(run.round)" + (run.maxRounds.map { " / \($0)" } ?? " · tur sınırı yok")
        if let notes = run.lastNotes?.split(separator: "\n").first, run.round > 1 {
            line += " · önceki turda istenen: “\(notes)”"
        }
        if let target = run.conflictTarget {
            line += " · \(target) ile çakışma çözülüyor"
        }
        return line
    }

    // MARK: Agents

    private func agents(team: OrchestraTeam, run: OrchestraRun?, record: BoardCard.RunRecord?) -> some View {
        let over = run?.isActive != true
        let planning = run?.phase == .planning
        var slots: [AgentSlot] = []
        if team.plans {
            slots.append(AgentSlot(id: "planner", stage: .plan, role: "Planlayıcı", member: team.planner, tab: run?.plannerTab,
                                   waiting: nil, done: record?.plan.map { $0.blocked == nil ? "Plan hazır" : "Bilgi istedi" }))
        }
        slots.append(AgentSlot(id: "developer", stage: .develop, role: "Geliştirici", member: team.developer, tab: run?.developerTab,
                               waiting: planning ? "Plan hazır olunca başlar" : nil))
        if let run, !run.reviewers.isEmpty {
            let reviewers = run.reviewers.sorted { lhs, rhs in
                (team.reviewers.firstIndex { $0.id == lhs.value.id } ?? 0) < (team.reviewers.firstIndex { $0.id == rhs.value.id } ?? 0)
            }
            for (index, reviewer) in reviewers.enumerated() {
                slots.append(AgentSlot(id: reviewer.key.uuidString, stage: .review, role: reviewerRole(index, of: reviewers.count),
                                       member: reviewer.value, tab: reviewer.key, verdict: run.verdicts[reviewer.key], waiting: nil))
            }
        } else {
            for (index, member) in team.reviewers.enumerated() {
                slots.append(AgentSlot(id: member.id.uuidString, stage: .review, role: reviewerRole(index, of: team.reviewers.count),
                                       member: member, tab: nil, waiting: over ? nil : "Geliştirici commit'leyince başlar"))
            }
        }
        if team.reviewers.count > 1 {
            slots.append(AgentSlot(id: "judge", stage: .judge, role: "Karar verici", member: team.judge, tab: run?.judgeTab,
                                   waiting: over ? nil : "Değerlendirmelerin hepsi gelince başlar"))
        }
        // Once the run is over: who got to work before it stopped.
        let reached = RunStage.reached(record?.events ?? [])
        func finished(_ slot: AgentSlot) -> String? {
            guard over else { return nil }
            if record?.isMerged == true { return "Bitti" }
            if slot.done != nil { return nil } // the planner that planned shows that
            return slot.stage <= reached ? "Durdu" : "Başlamadı"
        }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(slots) { slot in
                AgentSlotView(slot: slot, session: slot.tab.flatMap { store.claudeTab($0)?.session }, finished: finished(slot)) {
                    if let tab = slot.tab { store.focusTab(tab) }
                }
            }
        }
    }

    private func reviewerRole(_ index: Int, of count: Int) -> String {
        count > 1 ? "Gözden geçiren \(index + 1)" : "Gözden geçiren"
    }

    // MARK: Timeline

    private func timeline(_ events: [BoardCard.RunEvent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Akış")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 6)
            if events.isEmpty {
                Text("Henüz bir adım yok.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            // Days show only when the story is older than today; then every row gets the room.
            let showsDays = events.contains { !Calendar.current.isDateInToday($0.date) }
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                RunEventRow(event: event, showsDay: showsDays, isLast: index == events.count - 1)
            }
        }
    }
}

// MARK: - Pieces

/// Long text cut to a few lines, with a toggle to read all of it: reviews run to dozens of lines.
private struct ExpandableText: View {
    let text: String
    var lines: Int
    var font: Font = .system(size: 11.5)
    var isSecondary = true
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(font)
                .foregroundStyle(isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(isExpanded ? nil : lines)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if isLong {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Label(isExpanded ? "Daralt" : "Tamamını göster (\(lineCount) satır)",
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

    /// More lines than shown, or lines long enough to wrap past them (about 110 characters a line).
    private var isLong: Bool { lineCount > lines || text.count > lines * 110 }
}

/// Why the run stopped and the way on: the planner's questions to answer, or starting over.
private struct StopPanel: View {
    let reason: String
    /// The planner's questions when the card waits for answers; nil for any other stop.
    let questions: [String]?
    /// "Devam Et" for a run stopped on a limit, e.g. "Devam Et (+2 tur)".
    let continueTitle: String?
    let carryOn: () -> Void
    let restart: (String?) -> Void
    @State private var answer = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: questions == nil ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(questions == nil ? "Orkestra durdu" : "Planlayıcı senden bilgi istiyor")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let questions {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        Text("\(index + 1). \(question)")
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                    TextEditor(text: $answer)
                        .font(.system(size: 12))
                        .frame(minHeight: 70, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        .overlay(alignment: .topLeading) {
                            if answer.isEmpty {
                                Text("Cevapların; kartın notuna eklenir")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        Spacer()
                        Button("Cevapla ve Baştan Başlat") { restart(answer) }
                            .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(continueTitle == nil
                             ? "Geliştiricinin sekmesinde yanıtlayıp commit'letirsen koşu kaldığı yerden sürer; ya da kartın notunu düzeltip baştan başlat."
                             : "Devam Et aynı dalda kaldığı yerden, tur sınırı olmadan sürdürür. Baştan Başlat dalı silip sıfırdan başlar; yapılan iş gider.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        if let continueTitle {
                            Button(continueTitle, action: carryOn)
                                .help("Aynı dalda kaldığı yerden sürdürür, yapılan iş kalır; bu kartta tur sınırı kalkar")
                        }
                        Button("Baştan Başlat") { restart(nil) }
                            .help("Dalı ve worktree'yi silip kartı orkestrayla yeniden başlat; akış kalır")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

/// The planner's plan: how it understood the work, how to do it, when it counts as done, and the
/// ideas it had. Bigger ideas wait here for the user to put them on the board.
private struct PlanSection: View {
    let plan: BoardCard.RunPlan
    let planner: OrchestraTeam.Member?
    let addIdea: (BoardCard.RunPlan.Idea) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Plan")
                    .font(.system(size: 13, weight: .semibold))
                if let planner {
                    Text(planner.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Self.markdown(plan.summary)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
            if !plan.approach.isEmpty {
                part("Yaklaşım") {
                    Self.markdown(plan.approach)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
            }
            if !plan.doneCriteria.isEmpty {
                part("“Bitti” ölçütleri") {
                    ForEach(Array(plan.doneCriteria.enumerated()), id: \.offset) { _, criterion in
                        line(criterion, symbol: "checkmark.circle", tint: .green)
                    }
                }
            }
            if !plan.includedIdeas.isEmpty {
                part("Bu işe dahil edilen katkılar") {
                    ForEach(Array(plan.includedIdeas.enumerated()), id: \.offset) { _, idea in
                        line(idea, symbol: "plus.circle", tint: .accentColor)
                    }
                }
            }
            if !plan.separateIdeas.isEmpty {
                part("Ayrı iş önerileri") {
                    ForEach(plan.separateIdeas) { idea in
                        ideaRow(idea)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.175) : .white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.08))
        }
    }

    private func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func line(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Self.markdown(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    private func ideaRow(_ idea: BoardCard.RunPlan.Idea) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(idea.title)
                    .font(.system(size: 12, weight: .medium))
                if !idea.detail.isEmpty {
                    Self.markdown(idea.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if idea.isOnBoard {
                Label("Panoda", systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Panoya Ekle") { addIdea(idea) }
                    .controlSize(.small)
                    .help("Yapılacak'ın sonuna ayrı bir kart olarak ekle")
            }
        }
    }

    /// Inline markdown (code, bold), line breaks kept; plain text when it doesn't parse.
    static func markdown(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)).map(Text.init) ?? Text(text)
    }
}

private enum StageState {
    case done, current, stopped, upcoming
}

private struct StageChip: View {
    let stage: RunStage
    let state: StageState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
            Text(stage.title)
                .font(.system(size: 12, weight: state == .current ? .semibold : .regular))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(state == .upcoming ? 0.06 : 0.13)))
        .overlay {
            if state == .current {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 1)
            }
        }
        .accessibilityLabel("\(stage.title): \(accessibilityState)")
    }

    private var symbol: String {
        switch state {
        case .done: "checkmark"
        case .current: "circle.dotted"
        case .stopped: "exclamationmark"
        case .upcoming: "circle"
        }
    }

    private var tint: Color {
        switch state {
        case .done: .green
        case .current: .accentColor
        case .stopped: .orange
        case .upcoming: .secondary
        }
    }

    private var accessibilityState: String {
        switch state {
        case .done: "tamamlandı"
        case .current: "şu an burada"
        case .stopped: "burada durdu"
        case .upcoming: "sırada"
        }
    }
}

private struct AgentSlot: Identifiable {
    let id: String
    let stage: RunStage
    let role: String
    let member: OrchestraTeam.Member
    let tab: UUID?
    var verdict: OrchestraRun.Verdict?
    /// Why it hasn't started, while the run goes on.
    let waiting: String?
    /// Its part is done and its tab closed, e.g. "Plan hazır".
    var done: String?
}

/// One agent of the run: who it is, its state, what it is doing or said last.
private struct AgentSlotView: View {
    let slot: AgentSlot
    let session: TerminalSession?
    /// "Bitti", "Durdu" or "Başlamadı" once the run is over and its agent is gone.
    let finished: String?
    let open: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var activity: AgentActivity? { session?.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(slot.role)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                statePill
            }
            Text(slot.member.title
                 + (slot.member.effort.map { " · düşünme: \(AgentModels.effortTitle($0).lowercased(with: Locale(identifier: "tr")))" } ?? "")
                 + (slot.member.focus.isEmpty ? "" : " · odak: \(slot.member.focus)"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let activity {
                live(activity)
            } else if let waiting = slot.waiting {
                Text(waiting)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            if let verdict = slot.verdict {
                verdictLine(verdict)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: isHovering && session != nil ? 0.2 : 0.175) : .white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isWorking ? Color.accentColor.opacity(0.7) : Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.08),
                              lineWidth: isWorking ? 1.2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { if session != nil { open() } }
        .help(session != nil ? "Sohbetini aç" : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(session != nil ? .isButton : [])
    }

    private var isWorking: Bool { activity?.state == .working }

    @ViewBuilder
    private func live(_ activity: AgentActivity) -> some View {
        if activity.state == .working, let step = activity.currentStep {
            Text("› " + step)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(2)
        } else if let said = (activity.lastReply ?? activity.message)?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
            ExpandableText(text: said, lines: 3, font: .system(size: 12), isSecondary: false)
        }
        if !activity.touchedFiles.isEmpty {
            Label("\(activity.touchedFiles.count) dosya", systemImage: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func verdictLine(_ verdict: OrchestraRun.Verdict) -> some View {
        let (text, tint): (String, Color) = switch verdict.approved {
        case true: ("Onayladı", .green)
        case false: ("Değişiklik istedi", .orange)
        default: ("Karar bildirmedi", .secondary)
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
            if !verdict.notes.isEmpty {
                ExpandableText(text: verdict.notes, lines: 4)
            }
        }
    }

    private var statePill: some View {
        let (text, tint) = state
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.13)))
    }

    private var state: (String, Color) {
        guard let activity else {
            if let finished { return (finished, finished == "Bitti" ? .green : .secondary) }
            if let done = slot.done { return (done, .green) }
            return slot.waiting == nil ? ("Kapandı", .secondary) : ("Sırasını bekliyor", .secondary)
        }
        switch activity.state {
        case .starting: return ("Başlıyor", .secondary)
        case .idle: return ("Hazır", .secondary)
        case .working:
            let minutes = activity.turnStartedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
            return (minutes > 0 ? "Çalışıyor · \(minutes) dk" : "Çalışıyor", .accentColor)
        case .needsPermission: return ("Onay bekliyor", .orange)
        case .finished: return ("Turu bitti", .green)
        case .ended: return ("Kapandı", .secondary)
        }
    }
}

/// A step in the run's story, with when it happened.
private struct RunEventRow: View {
    let event: BoardCard.RunEvent
    let showsDay: Bool
    let isLast: Bool

    private static let dayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: showsDay ? 84 : 46, alignment: .leading)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                if let detail = event.detail {
                    ExpandableText(text: detail, lines: 8, font: .system(size: 11.5, design: event.kind == .commits ? .monospaced : .default))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !isLast { Divider() }
        }
    }

    private var time: String {
        showsDay ? Self.dayAndTime.string(from: event.date) : event.date.formatted(date: .omitted, time: .shortened)
    }

    private var symbol: String {
        switch event.kind {
        case .planning: "map"
        case .planned: "checklist"
        case .blocked: "questionmark.circle"
        case .started, .resumed: "play.fill"
        case .commits: "smallcircle.filled.circle"
        case .reminder: "bell"
        case .review: "eye"
        case .approved: "checkmark.circle"
        case .changesRequested: "arrow.uturn.backward.circle"
        case .silent: "speaker.slash"
        case .judging: "scalemass"
        case .round: "arrow.clockwise"
        case .conflict: "exclamationmark.triangle"
        case .merged: "arrow.triangle.merge"
        case .pushed: "arrow.up.circle"
        case .pushFailed: "exclamationmark.arrow.circlepath"
        case .stopped: "stop.circle"
        case .note: "info.circle"
        case .query: "cylinder.split.1x2"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .approved, .merged, .pushed, .planned: .green
        case .changesRequested, .conflict, .reminder, .silent, .pushFailed, .blocked: .orange
        case .stopped: .red
        case .started, .resumed, .review, .judging, .planning: .accentColor
        default: .secondary
        }
    }
}
