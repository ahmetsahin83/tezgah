import SwiftUI

/// A permission or question dialog that Claude Code shows in the terminal, answered natively.
///
/// Answers are the keys the terminal dialog takes: the option's number, or Esc for "no".
struct ClaudeRequestCard: View {
    let activity: ClaudeActivity
    let project: Project
    let answer: (TerminalSession.ClaudeKey) -> Void
    let answerQuestions: ([TerminalSession.QuestionAnswer]) -> Void
    let showTerminal: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let request = activity.pendingRequest {
                switch request.tool {
                case "AskUserQuestion":
                    question(request)
                case "ExitPlanMode":
                    plan
                default:
                    permission(request)
                }
            } else {
                unknown
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.17) : Color.white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 12, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(colorScheme == .dark ? 0.45 : 0.4), lineWidth: 1)
        }
    }

    // MARK: Permission

    private func permission(_ request: ClaudeActivity.PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(symbol: "hand.raised.fill", title: "Claude izin istiyor", subtitle: Self.action(for: request))
            if let detail = detail(for: request) {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            if let reason = request.input["description"]?.string, request.tool == "Bash" {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Terminalde Gör", action: showTerminal)
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                    .help("Claude Code'un kendi penceresini terminalde göster")
                Spacer(minLength: 8)
                Button {
                    answer(.escape)
                } label: {
                    Text("Reddet").frame(minWidth: 54)
                }
                .help("Reddet (Esc)")
                if let always = Self.alwaysLabel(request.suggestions) {
                    Button {
                        answer(.option(2))
                    } label: {
                        Text(always)
                    }
                    .help(always)
                }
                Button {
                    answer(.option(1))
                } label: {
                    Text("İzin Ver").frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(.claudeAccent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("İzin ver (⌘↩)")
            }
            .controlSize(.regular)
        }
    }

    private func detail(for request: ClaudeActivity.PendingRequest) -> String? {
        let input = request.input
        if let command = input["command"]?.string { return command }
        if let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string {
            return relative(path)
        }
        if let url = input["url"]?.string { return url }
        if let query = input["query"]?.string { return query }
        return nil
    }

    private func relative(_ path: String) -> String {
        let relative = project.relativePath(of: URL(fileURLWithPath: path))
        return relative == path ? (path as NSString).abbreviatingWithTildeInPath : relative
    }

    /// What the tool is about to do, in words.
    static func action(for request: ClaudeActivity.PendingRequest) -> String {
        switch request.tool {
        case "Bash": "Bir komut çalıştırmak istiyor"
        case "Write": "Bir dosya yazmak istiyor"
        case "Edit", "MultiEdit": "Bir dosyayı düzenlemek istiyor"
        case "NotebookEdit": "Bir notebook'u düzenlemek istiyor"
        case "Read": "Proje dışından bir dosya okumak istiyor"
        case "WebFetch": "Bir web sayfasını almak istiyor"
        case "WebSearch": "Web'de arama yapmak istiyor"
        case let tool where tool.hasPrefix("mcp__"):
            "MCP aracı: " + tool.split(separator: "_", omittingEmptySubsequences: true).dropFirst().joined(separator: " · ")
        default: "\(request.tool) aracını kullanmak istiyor"
        }
    }

    /// Option 2 of the terminal dialog, which Claude Code builds from its suggestions.
    static func alwaysLabel(_ suggestions: [JSONValue]) -> String? {
        guard let first = suggestions.first else { return nil }
        switch first["type"]?.string {
        case "setMode":
            return first["mode"]?.string == "acceptEdits" ? "Düzenlemeleri Hep Kabul Et" : "Evet, Modu Değiştir"
        case "addDirectories":
            return "Bu Klasöre Hep İzin Ver"
        default:
            return "Bir Daha Sorma"
        }
    }

    // MARK: Question

    private func question(_ request: ClaudeActivity.PendingRequest) -> some View {
        QuestionForm(questions: request.input["questions"]?.array ?? [], showTerminal: showTerminal) { answers in
            answerQuestions(answers)
        } header: { subtitle in
            header(symbol: "questionmark.bubble.fill", title: "Claude soruyor", subtitle: subtitle)
        }
    }

    // MARK: Plan

    private var plan: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(symbol: "list.bullet.clipboard.fill", title: "Plan hazır", subtitle: "Plan yukarıda. Onaylarsan Claude uygulamaya başlar.")
            HStack(spacing: 8) {
                Spacer()
                Button("Diğer Seçenekler…", action: showTerminal)
                    .help("Claude Code'un plan seçenekleri terminalde")
                Button {
                    answer(.option(1))
                } label: {
                    Text("Onayla ve Başla").frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(.claudeAccent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var unknown: some View {
        HStack(spacing: 10) {
            header(symbol: "exclamationmark.bubble.fill", title: "Claude yanıtını bekliyor", subtitle: activity.message)
            Spacer()
            Button("Terminali Göster", action: showTerminal)
                .buttonStyle(.borderedProminent)
                .tint(.claudeAccent)
        }
    }

    private func header(symbol: String, title: String, subtitle: String?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.orange.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

/// Claude's questions as a form: pick for each, then send. A single question with a single
/// choice answers on click, like the terminal does.
private struct QuestionForm<Header: View>: View {
    let questions: [JSONValue]
    let showTerminal: () -> Void
    let submit: ([TerminalSession.QuestionAnswer]) -> Void
    @ViewBuilder let header: (String?) -> Header

    @State private var picked: [Int: Set<Int>] = [:]
    @State private var custom: [Int: String] = [:]
    @State private var isTypingCustom: Set<Int> = []
    @State private var isSent = false

    private var isInstant: Bool {
        questions.count == 1 && questions[0]["multiSelect"]?.bool != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(questions.count > 1 ? "\(questions.count) soru" : questions.first?["header"]?.string)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionView(index, question)
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Terminalde Yanıtla", action: showTerminal)
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                Spacer()
                if !isInstant || isTypingCustom.contains(0) {
                    if !isComplete {
                        Text("\(answeredCount)/\(questions.count) yanıtlandı")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        send()
                    } label: {
                        Text("Gönder").frame(minWidth: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.claudeAccent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!isComplete || isSent)
                    .help("Yanıtları gönder (⌘↩)")
                }
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private func questionView(_ index: Int, _ question: JSONValue) -> some View {
        let isMulti = question["multiSelect"]?.bool == true
        let options = question["options"]?.array ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if questions.count > 1, let chip = question["header"]?.string {
                    Text(chip)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                if isMulti {
                    Text("birden fazla seçilebilir")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(question["question"]?.string ?? "")
                .font(.system(size: 13.5, weight: .semibold))
            ForEach(Array(options.enumerated()), id: \.offset) { optionIndex, option in
                OptionRow(
                    number: optionIndex + 1,
                    label: option["label"]?.string ?? "",
                    description: option["description"]?.string,
                    isMulti: isMulti,
                    isSelected: picked[index, default: []].contains(optionIndex + 1)
                ) {
                    pick(optionIndex + 1, in: index, isMulti: isMulti)
                }
            }
            if !isMulti {
                CustomAnswerRow(
                    number: options.count + 1,
                    text: Binding(get: { custom[index] ?? "" }, set: { custom[index] = $0 }),
                    isActive: isTypingCustom.contains(index)
                ) {
                    isTypingCustom.insert(index)
                    picked[index] = []
                } submit: {
                    if isInstant { send() }
                }
            }
        }
    }

    private func pick(_ option: Int, in question: Int, isMulti: Bool) {
        guard !isSent else { return }
        if isMulti {
            var set = picked[question, default: []]
            if set.contains(option) { set.remove(option) } else { set.insert(option) }
            picked[question] = set
        } else {
            picked[question] = [option]
            isTypingCustom.remove(question)
            custom[question] = nil
            if isInstant { send() }
        }
    }

    private func isAnswered(_ index: Int) -> Bool {
        if isTypingCustom.contains(index) { return !(custom[index] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        return !picked[index, default: []].isEmpty
    }

    private var answeredCount: Int { questions.indices.filter(isAnswered).count }
    private var isComplete: Bool { answeredCount == questions.count }

    private func send() {
        guard isComplete, !isSent else { return }
        isSent = true
        submit(questions.enumerated().map { index, question in
            TerminalSession.QuestionAnswer(
                options: Array(picked[index, default: []]),
                customText: isTypingCustom.contains(index) ? custom[index] : nil,
                isMultiSelect: question["multiSelect"]?.bool == true,
                optionCount: question["options"]?.array?.count ?? 0
            )
        })
    }
}

private struct OptionRow: View {
    let number: Int
    let label: String
    let description: String?
    let isMulti: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isMulti
                      ? (isSelected ? "checkmark.square.fill" : "square")
                      : (isSelected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.claudeAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                    if let description, !description.isEmpty, description != label {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.claudeAccent.opacity(0.12) : Color.primary.opacity(isHovering ? 0.07 : 0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.claudeAccent.opacity(0.5) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// "Diğer…": an answer of one's own instead of the options.
private struct CustomAnswerRow: View {
    let number: Int
    @Binding var text: String
    let isActive: Bool
    let activate: () -> Void
    let submit: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Color.claudeAccent : Color.secondary)
            if isActive {
                TextField("Kendi cevabını yaz…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onAppear { isFocused = true }
            } else {
                Text("Diğer…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color.claudeAccent.opacity(0.12) : Color.primary.opacity(isHovering ? 0.07 : 0.035))
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isActive { activate() } }
        .onHover { isHovering = $0 }
    }
}
