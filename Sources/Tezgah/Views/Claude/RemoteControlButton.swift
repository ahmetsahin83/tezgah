import CoreImage.CIFilterBuiltins
import SwiftUI

/// 📡 in a Claude tab's bar: turns Remote Control on, and once connected shows the session's link and QR code.
struct RemoteControlButton: View {
    let activity: ClaudeActivity
    let project: Project
    @State private var isBusy = false
    @State private var isShowingLink = false
    @State private var error: String?

    private var session: TerminalSession? {
        project.terminals.first { $0.claude === activity }
    }

    var body: some View {
        Button {
            switch activity.remoteControl {
            case .off: run { await $0.enableRemoteControl() }
            case .connecting, .active: isShowingLink = true
            }
        } label: {
            HStack(spacing: 4) {
                if isBusy || activity.remoteControl == .connecting {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(activity.remoteControl.isOn ? Color.green : .secondary)
                }
                if activity.remoteControl.isOn {
                    Text(activity.remoteControl == .connecting ? "Bağlanıyor" : "Uzaktan")
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(activity.state == .ended || activity.state == .starting || isBusy)
        .help(help)
        .accessibilityLabel(activity.remoteControl.isOn ? "Uzaktan erişim açık" : "Uzaktan erişimi aç")
        .popover(isPresented: $isShowingLink, arrowEdge: .top) {
            RemoteControlPanel(activity: activity) {
                isShowingLink = false
                run { await $0.disableRemoteControl() }
            }
        }
        .alert("Uzaktan erişim", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var help: String {
        switch activity.remoteControl {
        case .off: "Uzaktan erişimi aç: oturumu Claude uygulamasından ya da claude.ai/code'dan takip et ve yanıtla"
        case .connecting: "Uzaktan erişim bağlanıyor"
        case .active: "Uzaktan erişim açık: bağlantı ve QR kod"
        }
    }

    private func run(_ action: @escaping (TerminalSession) async -> String?) {
        guard let session else { return }
        isBusy = true
        Task {
            error = await action(session)
            isBusy = false
        }
    }
}

private struct RemoteControlPanel: View {
    let activity: ClaudeActivity
    let disconnect: () -> Void

    private var link: URL? {
        if case .active(let link) = activity.remoteControl { return link }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                Text("Uzaktan erişim açık")
                    .font(.headline)
            }
            Text("Oturum bu Mac'te çalışmaya devam ediyor. Claude uygulamasının Code sekmesinden ya da tarayıcıdan takip edip yanıtlayabilirsin. Açıkken Mac uykuya geçmez.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let link {
                HStack {
                    Spacer()
                    if let image = Self.qrCode(for: link.absoluteString) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 168, height: 168)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                            .accessibilityLabel("Oturum bağlantısının QR kodu")
                    }
                    Spacer()
                }
                Text("Telefonunun kamerasıyla okut")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Text(link.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Bağlantı bekleniyor…").foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Bağlantıyı Kes", role: .destructive, action: disconnect)
                Spacer()
                Button("Kopyala") {
                    guard let link else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
                .disabled(link == nil)
                Button("Tarayıcıda Aç") {
                    if let link { NSWorkspace.shared.open(link) }
                }
                .disabled(link == nil)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
        // Opened from the status bar, whose single-line caption style would otherwise carry over.
        .lineLimit(nil)
        .font(.body)
        .foregroundStyle(.primary)
    }

    static func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
