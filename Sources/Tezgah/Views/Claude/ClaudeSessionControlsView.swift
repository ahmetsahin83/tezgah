import SwiftUI

/// Mode, model and effort of the session, as small menus in the composer's bottom bar.
struct ClaudeSessionControlsView: View {
    let session: TerminalSession
    let activity: ClaudeActivity
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 2) {
            modeMenu
            modelMenu
            effortMenu
            if let busy {
                ProgressView().controlSize(.mini)
                Text(busy).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .task {
            if activity.permissionMode == nil, let mode = session.claudeModeOnScreen() {
                activity.permissionMode = mode.rawValue
            }
        }
        .onChange(of: activity.usage?.model) {
            if activity.usage?.model == activity.pendingModel { activity.pendingModel = nil }
        }
    }

    private var isIdle: Bool {
        activity.state == .idle || activity.state == .finished
    }

    // MARK: Mode

    private var mode: TerminalSession.ClaudeMode? {
        activity.permissionMode.flatMap(TerminalSession.ClaudeMode.init(rawValue:))
    }

    /// Bypass permissions only exists in sessions started for it.
    private var modes: [TerminalSession.ClaudeMode] {
        TerminalSession.ClaudeMode.allCases.filter { $0 != .bypassPermissions || activity.canSkipPermissions || $0 == mode }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(modes) { option in
                Button {
                    change("Mod") {
                        await session.setClaudeMode(option) ? nil : "Mod değişmedi; terminalde ⇧⇥ ile dene."
                    }
                } label: {
                    Label {
                        Text(option.title) + Text("\n" + option.detail).font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: option == mode ? "checkmark" : option.symbol)
                    }
                }
            }
        } label: {
            pill(symbol: mode?.symbol ?? "bolt", text: mode?.title ?? "Mod", tint: modeTint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mode.map { "\($0.title): \($0.detail) (⇧⇥ ile değişir)" } ?? "İzin modu")
        .disabled(busy != nil || activity.state == .ended || activity.state == .starting)
    }

    private var modeTint: Color {
        switch mode {
        case .plan: .teal
        case .manual: .secondary
        case .bypassPermissions: .orange
        default: .claudeAccent
        }
    }

    // MARK: Model

    private var currentModel: String? { activity.pendingModel ?? activity.usage?.model }

    private var modelMenu: some View {
        Menu {
            ForEach(TerminalSession.models, id: \.self) { model in
                Button {
                    change("Model") { await session.setClaudeModel(model) }
                } label: {
                    Label(model, systemImage: currentModel?.hasPrefix(model) == true ? "checkmark" : "cpu")
                }
            }
            Divider()
            Text("Yalnızca bu oturum için; varsayılanın değişmez")
        } label: {
            pill(symbol: "cpu", text: currentModel ?? "Model", tint: .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isIdle ? "Model (bu oturum için)" : "Model, Claude'un turu bitince değiştirilebilir")
        .disabled(busy != nil || !isIdle)
    }

    // MARK: Effort

    private var effortMenu: some View {
        Menu {
            ForEach(TerminalSession.effortLevels, id: \.self) { level in
                Button {
                    change("Effort") { await session.setClaudeEffort(level) }
                } label: {
                    Label(Self.effortTitle(level), systemImage: level == (activity.effortLevel ?? "medium") ? "checkmark" : "gauge.with.dots.needle.33percent")
                }
            }
            Divider()
            Text("Yalnızca bu oturum için")
        } label: {
            pill(symbol: Self.effortSymbol(activity.effortLevel ?? "medium"), text: Self.effortTitle(activity.effortLevel ?? "medium"), tint: .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isIdle ? "Ne kadar derin düşüneceği (bu oturum için)" : "Effort, Claude'un turu bitince değiştirilebilir")
        .disabled(busy != nil || !isIdle)
    }

    static func effortTitle(_ level: String) -> String {
        switch level {
        case "low": "Hızlı"
        case "medium": "Dengeli"
        case "high": "Derin"
        case "xhigh": "Çok derin"
        case "max": "En derin"
        default: level
        }
    }

    static func effortSymbol(_ level: String) -> String {
        switch level {
        case "low": "gauge.with.dots.needle.0percent"
        case "medium": "gauge.with.dots.needle.33percent"
        case "high": "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }

    // MARK: Helpers

    private func pill(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
        .contentShape(Capsule())
    }

    private func change(_ label: String, _ action: @escaping () async -> String?) {
        busy = label + "…"
        error = nil
        Task {
            error = await action()
            busy = nil
            activity.composer.focus()
        }
    }
}
