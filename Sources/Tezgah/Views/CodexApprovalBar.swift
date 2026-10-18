import SwiftUI

/// Codex's approval dialog with buttons, for answering it without the keyboard: above a Codex
/// tab's terminal and in the sessions overview. The dialog is read off the screen, which no
/// state change announces, so it is looked at again while the request is open.
struct CodexApprovalBar: View {
    let session: TerminalSession
    /// One line, for the overview.
    var isCompact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if let dialog = session.codexApproval {
                if isCompact {
                    buttons(dialog)
                } else {
                    bar(dialog)
                }
            }
        }
    }

    private func bar(_ dialog: CodexApprovalDialog) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(dialog))
                    .font(.system(size: 12.5, weight: .semibold))
                if let command = dialog.command {
                    Text(command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let reason = dialog.reason {
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            buttons(dialog)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func buttons(_ dialog: CodexApprovalDialog) -> some View {
        HStack(spacing: 6) {
            Button("Reddet") { session.answerCodex(nil) }
                .help("İptal et; Codex'e ne yapacağını terminalden söyleyebilirsin")
            if let always = dialog.alwaysOption {
                Button("Bir Daha Sorma") { session.answerCodex(always) }
                    .help(always.label)
            }
            if let allow = dialog.options.first, allow.allows {
                Button("İzin Ver") { session.answerCodex(allow) }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentProvider.codex.accent)
                    .help(allow.label)
            }
        }
        .controlSize(.small)
    }

    /// Codex asks in English; the common questions read in Turkish.
    static func title(_ dialog: CodexApprovalDialog) -> String {
        switch dialog.title {
        case "Would you like to run the following command?": "Codex bir komut çalıştırmak istiyor"
        case "Would you like to make the following edits?": "Codex dosyaları düzenlemek istiyor"
        case "Would you like to grant these permissions?": "Codex ek izin istiyor"
        default: dialog.title
        }
    }
}
