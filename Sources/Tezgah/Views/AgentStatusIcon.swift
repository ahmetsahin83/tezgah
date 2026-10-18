import SwiftUI

/// The state of one agent session, or the most urgent of several, as a small icon.
struct AgentStatusIcon: View {
    let state: AgentActivity.State
    let isUnseen: Bool
    let provider: AgentProvider

    init(_ activity: AgentActivity) {
        state = activity.state
        isUnseen = activity.isUnseen
        provider = activity.provider
    }

    /// The most urgent state among a project's sessions, or nil if there is nothing to show.
    init?(summarizing activities: [AgentActivity]) {
        guard let urgent = activities.first(where: { $0.state == .needsPermission })
            ?? activities.first(where: { $0.state == .finished && $0.isUnseen })
            ?? activities.first(where: { $0.state == .working }) else { return nil }
        self.init(urgent)
    }

    var body: some View {
        Group {
            switch state {
            case .working:
                ProgressView()
                    .controlSize(.mini)
            case .needsPermission:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .finished where isUnseen:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            default:
                Image(systemName: provider.symbol)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14)
        .help(helpText)
    }

    private var helpText: String {
        let name = provider.displayName
        return switch state {
        case .starting: "\(name) başlıyor"
        case .idle: "\(name) hazır"
        case .working: "\(name) çalışıyor"
        case .needsPermission: "\(name) onay bekliyor"
        case .finished: "\(name) bitirdi"
        case .ended: "\(name) kapandı"
        }
    }
}

extension AgentProvider {
    var accent: Color {
        switch self {
        case .claude: .claudeAccent
        case .codex: Color(hex: 0x10A37F)
        }
    }
}
